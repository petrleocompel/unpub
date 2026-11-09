import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../config/config.dart';
import '../logging.dart';
import '../store/package_store.dart';
import '../store/upstream_cache_store.dart';
import '../validation.dart';
import '../version.dart';

final _log = Logger('unpub.upstream');

/// Largest metadata response read from the upstream.
const _maxMetadataBytes = 64 * 1024 * 1024;

/// Largest archive read from the upstream. pub.dev itself accepts 100 MiB.
const _maxArchiveBytes = 256 * 1024 * 1024;

/// How long past `cacheTtl` an entry stays, for revalidation and so that a
/// cached archive keeps its validator.
const _staleRetention = Duration(days: 7);

/// How many redirects one upstream request may follow.
const _maxRedirects = 3;

const _pubAccept = 'application/vnd.pub.v2+json';
final _userAgent = 'unpub/$packageVersion '
    '(+https://github.com/petrleocompel/unpub)';
final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

/// The upstream could not give a usable answer.
class UpstreamException implements Exception {
  final String message;

  const UpstreamException(this.message);

  @override
  String toString() => message;
}

/// A package listing from the upstream, ready to serve.
class UpstreamListing {
  /// The pub API response, with `archive_url` as a path on this server.
  final Map<String, dynamic> json;

  /// The upstream URL of each version's archive.
  final Map<String, String> archiveUrls;

  /// Changes whenever the listing does.
  final String digest;

  const UpstreamListing(this.json, this.archiveUrls, this.digest);

  /// The entry for [version] in [json], or null.
  Map<String, dynamic>? version(String version) {
    for (final item in json['versions'] as List) {
      if (item['version'] == version) return item as Map<String, dynamic>;
    }
    return null;
  }

  String? sha256Of(String version) =>
      this.version(version)?['archive_sha256'] as String?;
}

/// A JSON document passed through from the upstream, ready to serve.
class UpstreamDocument {
  final Map<String, dynamic> json;
  final String digest;

  const UpstreamDocument(this.json, this.digest);
}

/// An archive obtained through the proxy.
class UpstreamArchive {
  final Stream<List<int>> content;

  /// Lowercase hex SHA-256, when known.
  final String? sha256;

  const UpstreamArchive(this.content, this.sha256);
}

class _Response {
  final Uint8List? body;
  final String? etag;
  final bool notModified;

  const _Response(this.body, this.etag, {this.notModified = false});
}

/// Fetches packages this server does not have from an upstream registry, and
/// keeps metadata in [cache] and archives in [archives].
class UpstreamProxy {
  final Uri url;
  final Duration cacheTtl;
  final Set<String> allowlist;
  final Duration timeout;
  final UpstreamCacheStore cache;
  final PackageStore archives;
  final Set<String> allowedArchiveHosts;
  final http.Client _client;
  final DateTime Function() clock;

  final _inFlight = <String, Future<Object?>>{};

  UpstreamProxy({
    required UpstreamConfig config,
    required this.cache,
    required this.archives,
    http.Client? client,
    this.clock = DateTime.now,
  })  : url = config.url,
        cacheTtl = config.cacheTtl,
        allowlist = config.allowlist.toSet(),
        timeout = config.timeout,
        allowedArchiveHosts = config.allowedArchiveHosts.toSet(),
        _client = client ?? http.Client();

  void close() => _client.close();

  /// Whether [name] may be proxied at all.
  bool allows(String name) => allowlist.isEmpty || allowlist.contains(name);

  /// Runs [load], sharing the result with concurrent callers of the same [key].
  Future<T> _once<T>(String key, Future<T> Function() load) {
    final running = _inFlight[key];
    if (running != null) return running.then((value) => value as T);
    final future = load().whenComplete(() {
      _inFlight.remove(key);
    });
    _inFlight[key] = future;
    return future;
  }

  /// The upstream URL for [path], which starts with `/`, keeping any path
  /// that [url] has.
  Uri _resolve(String path) {
    final base = url.path.endsWith('/')
        ? url.path.substring(0, url.path.length - 1)
        : url.path;
    return url.replace(path: '$base$path');
  }

  bool _isFresh(UpstreamCacheEntry entry) =>
      clock().difference(entry.fetchedAt) < cacheTtl;

  DateTime _expiry(DateTime fetchedAt) =>
      fetchedAt.add(cacheTtl).add(_staleRetention);

  /// Whether the upstream has [name], preferring what is already cached.
  ///
  /// Throws an [UpstreamException] if the upstream cannot tell.
  Future<bool> packageExists(String name) async {
    if (await cache.read(name) != null) return true;
    return await listing(name) != null;
  }

  /// The listing of [name], or null if the upstream does not have it.
  ///
  /// Throws an [UpstreamException] if the upstream gives no usable answer.
  Future<UpstreamListing?> listing(String name) =>
      _once('listing:$name', () => _loadListing(name));

  Future<UpstreamListing?> _loadListing(String name) async {
    final cached = await cache.read(name);
    if (cached != null && _isFresh(cached)) return _decodeCached(cached);

    final response = await _getJson('/api/packages/$name', etag: cached?.etag);
    if (response == null) {
      if (cached != null) await _forget(name);
      return null;
    }
    if (response.notModified) {
      await _touch(name);
      return _decodeCached(cached!);
    }

    final (body, urls) = _rewriteListing(name, response.body!);
    final fetchedAt = clock();
    await _store(UpstreamCacheEntry(
      key: name,
      body: body,
      archiveUrls: json.encode(urls),
      etag: response.etag,
      fetchedAt: fetchedAt,
    ));
    return UpstreamListing(
        json.decode(body) as Map<String, dynamic>, urls, _digest(body));
  }

  UpstreamListing _decodeCached(UpstreamCacheEntry entry) => UpstreamListing(
        json.decode(entry.body) as Map<String, dynamic>,
        (json.decode(entry.archiveUrls ?? '{}') as Map).cast<String, String>(),
        _digest(entry.body),
      );

  static String _digest(String body) =>
      sha256.convert(utf8.encode(body)).toString();

  /// Keeps only the fields of the pub API, and points archives at this server.
  ///
  /// The cached form uses paths rather than absolute URLs. An absolute URL
  /// would hold the `Host` of whichever request came first, for every client.
  (String, Map<String, String>) _rewriteListing(String name, Uint8List body) {
    final Object? decoded;
    try {
      decoded = json.decode(utf8.decode(body));
    } on FormatException {
      throw const UpstreamException('the upstream sent an invalid listing');
    }
    if (decoded is! Map ||
        decoded['name'] != name ||
        decoded['versions'] is! List) {
      throw const UpstreamException('the upstream sent an invalid listing');
    }

    final urls = <String, String>{};
    Map<String, dynamic>? rewrite(Object? item) {
      if (item is! Map) return null;
      final version = item['version'];
      final archiveUrl = item['archive_url'];
      if (version is! String ||
          !isValidPackageVersion(version) ||
          archiveUrl is! String) {
        return null;
      }
      final parsed = Uri.tryParse(archiveUrl);
      if (parsed == null ||
          !(parsed.isScheme('http') || parsed.isScheme('https'))) {
        return null;
      }
      urls[version] = archiveUrl;
      final hash = item['archive_sha256'];
      return {
        'version': version,
        'pubspec': item['pubspec'],
        'archive_url': archivePath(name, version),
        if (hash is String && _sha256Pattern.hasMatch(hash))
          'archive_sha256': hash,
        if (item['published'] != null) 'published': item['published'],
        if (item['retracted'] == true) 'retracted': true,
      };
    }

    final versions =
        (decoded['versions'] as List).map(rewrite).nonNulls.toList();
    if (versions.isEmpty) {
      throw const UpstreamException('the upstream listing has no versions');
    }
    final latest = rewrite(decoded['latest']);
    final result = json.encode({
      'name': name,
      if (latest != null) 'latest': latest,
      'versions': versions,
      'isDiscontinued': decoded['isDiscontinued'] == true,
      if (decoded['replacedBy'] is String) 'replacedBy': decoded['replacedBy'],
      if (decoded['advisoriesUpdated'] != null)
        'advisoriesUpdated': decoded['advisoriesUpdated'],
    });
    return (result, urls);
  }

  /// Where this server serves the archive of [name] [version].
  static String archivePath(String name, String version) =>
      '/packages/$name/versions/$version.tar.gz';

  /// The advisories of [name], or null if the upstream has none to offer.
  ///
  /// Throws an [UpstreamException] if the upstream gives no usable answer.
  Future<UpstreamDocument?> advisories(String name) =>
      _once('advisories:$name', () => _loadAdvisories(name));

  Future<UpstreamDocument?> _loadAdvisories(String name) async {
    final key = 'advisories:$name';
    final cached = await cache.read(key);
    if (cached != null && _isFresh(cached)) {
      return UpstreamDocument(json.decode(cached.body) as Map<String, dynamic>,
          _digest(cached.body));
    }

    final response =
        await _getJson('/api/packages/$name/advisories', etag: cached?.etag);
    if (response == null) {
      if (cached != null) await _forget(key);
      return null;
    }
    if (response.notModified) {
      await _touch(key);
      return UpstreamDocument(json.decode(cached!.body) as Map<String, dynamic>,
          _digest(cached.body));
    }

    final String text;
    final Object? decoded;
    try {
      text = utf8.decode(response.body!);
      decoded = json.decode(text);
    } on FormatException {
      throw const UpstreamException('the upstream sent invalid advisories');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const UpstreamException('the upstream sent invalid advisories');
    }
    await _store(UpstreamCacheEntry(
      key: key,
      body: text,
      etag: response.etag,
      fetchedAt: clock(),
    ));
    return UpstreamDocument(decoded, _digest(text));
  }

  Future<void> _store(UpstreamCacheEntry entry) async {
    try {
      await cache.write(entry, _expiry(entry.fetchedAt));
    } catch (error, stackTrace) {
      _log.warning(
          LogEvent('failed to cache upstream metadata', {'key': entry.key}),
          error,
          stackTrace);
    }
  }

  Future<void> _touch(String key) async {
    final now = clock();
    try {
      await cache.touch(key, now, _expiry(now));
    } catch (error, stackTrace) {
      _log.warning(
          LogEvent('failed to refresh upstream metadata', {'key': key}),
          error,
          stackTrace);
    }
  }

  Future<void> _forget(String key) async {
    try {
      await cache.delete(key);
    } catch (error, stackTrace) {
      _log.warning(LogEvent('failed to forget upstream metadata', {'key': key}),
          error, stackTrace);
    }
  }

  /// The hash of [version] of [name] if the metadata is already here, without
  /// asking the upstream.
  Future<String?> knownSha256(String name, String version) async {
    final cached = await cache.read(name);
    if (cached == null) return null;
    return _decodeCached(cached).sha256Of(version);
  }

  /// The archive of [name] [version], from the store if it is there and
  /// otherwise fetched, verified and stored.
  ///
  /// The archive is fetched completely before the client gets a byte, because
  /// only then can a corrupt archive still be answered with an error status.
  /// Returns null if the upstream does not have it.
  ///
  /// Throws an [UpstreamException] if it cannot be fetched or fails to verify.
  Future<UpstreamArchive?> archive(String name, String version) async {
    if (await _isStored(name, version)) {
      return UpstreamArchive(archives.downloadUpstream(name, version),
          await knownSha256(name, version));
    }
    final fetched = await _once(
        'archive:$name@$version', () => _fetchArchive(name, version));
    if (fetched == null) return null;
    return UpstreamArchive(Stream.value(fetched.$1), fetched.$2);
  }

  /// A store that cannot be read is treated as not holding the archive, so
  /// that the upstream can still serve it.
  Future<bool> _isStored(String name, String version) async {
    try {
      return await archives.upstreamCached(name, version);
    } catch (error, stackTrace) {
      _log.warning(
          LogEvent('failed to look up cached archive',
              {'name': name, 'version': version}),
          error,
          stackTrace);
      return false;
    }
  }

  Future<(Uint8List, String?)?> _fetchArchive(
      String name, String version) async {
    final metadata = await listing(name);
    final archiveUrl = metadata?.archiveUrls[version];
    if (metadata == null || archiveUrl == null) return null;

    final response = await _get(Uri.parse(archiveUrl), _maxArchiveBytes);
    if (response == null) return null;
    final bytes = response.body!;

    final expected = metadata.sha256Of(version);
    final actual = sha256.convert(bytes).toString();
    if (expected != null && actual != expected) {
      _log.warning(LogEvent('upstream archive failed verification',
          {'name': name, 'version': version}));
      throw const UpstreamException(
          'the upstream archive did not match its published hash');
    }

    try {
      await archives.cacheUpstream(name, version, bytes);
    } catch (error, stackTrace) {
      // The client can still have the verified archive.
      _log.warning(
          LogEvent('failed to store upstream archive',
              {'name': name, 'version': version}),
          error,
          stackTrace);
    }
    return (bytes, expected ?? actual);
  }

  Future<_Response?> _getJson(String path, {String? etag}) =>
      _get(_resolve(path), _maxMetadataBytes, accept: _pubAccept, etag: etag);

  /// Refuses to go to [target] from [origin], which is a URL of the upstream
  /// or the one that redirected here.
  ///
  /// The URLs come from the upstream, and must not be able to point this
  /// server at something on its own network.
  void _checkTarget(Uri origin, Uri target) {
    final isHttp = target.isScheme('http') || target.isScheme('https');
    final isDowngrade = origin.isScheme('https') && target.isScheme('http');
    final isUpstream = target.scheme == url.scheme &&
        target.host == url.host &&
        target.port == url.port;
    if (isHttp &&
        !isDowngrade &&
        (isUpstream || allowedArchiveHosts.contains(target.host))) {
      return;
    }
    _log.warning(LogEvent('refused an upstream URL',
        {'scheme': target.scheme, 'host': target.host, 'port': target.port}));
    throw const UpstreamException(
        'the upstream pointed at a location that is not allowed');
  }

  /// Sends a GET for [uri], following redirects itself so that each hop is
  /// checked, and giving up after [timeout] without an answer.
  Future<http.StreamedResponse> _send(Uri uri,
      {String? accept, String? etag}) async {
    var origin = url;
    var target = uri;
    for (var redirects = 0;; redirects++) {
      _checkTarget(origin, target);
      final abort = Completer<void>();
      final request =
          http.AbortableRequest('GET', target, abortTrigger: abort.future)
            ..followRedirects = false
            ..headers['user-agent'] = _userAgent
            ..headers.addAll({
              if (accept != null) 'accept': accept,
              if (etag != null) 'if-none-match': etag,
            });
      final response =
          await _client.send(request).timeout(timeout, onTimeout: () {
        abort.complete();
        throw TimeoutException('no answer from the upstream', timeout);
      });
      if (!const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
        return response;
      }
      await _discard(response);
      final location = response.headers['location'];
      if (location == null) {
        throw const UpstreamException('the upstream sent an invalid redirect');
      }
      if (redirects == _maxRedirects) {
        throw const UpstreamException('the upstream sent too many redirects');
      }
      origin = target;
      target = target.resolve(location);
    }
  }

  /// Reads the [response] body to its end and drops it. The whole body has to
  /// arrive within [timeout], since nothing in it is worth waiting for.
  Future<void> _discard(http.StreamedResponse response) async {
    final done = Completer<void>();
    final subscription = response.stream.listen(null,
        onDone: done.complete,
        onError: done.completeError,
        cancelOnError: true);
    try {
      await done.future.timeout(timeout);
    } finally {
      await subscription.cancel();
    }
  }

  /// Returns null for a 404. Every failure is an [UpstreamException] that says
  /// nothing about the upstream's internals, and is logged here.
  Future<_Response?> _get(Uri uri, int limit,
      {String? accept, String? etag}) async {
    try {
      final response = await _send(uri, accept: accept, etag: etag);
      if (response.statusCode == 304) {
        await _discard(response);
        return _Response(null, etag, notModified: true);
      }
      if (response.statusCode == 404) {
        await _discard(response);
        return null;
      }
      if (response.statusCode != 200) {
        await _discard(response);
        _log.warning(LogEvent('upstream refused a request',
            {'status': response.statusCode, 'path': uri.path}));
        throw const UpstreamException(
            'the upstream registry refused the request');
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(timeout)) {
        builder.add(chunk);
        if (builder.length > limit) {
          throw const UpstreamException('the upstream response is too large');
        }
      }
      return _Response(builder.takeBytes(), response.headers['etag']);
    } on UpstreamException {
      rethrow;
    } catch (error, stackTrace) {
      // TimeoutException, SocketException, http.ClientException and so on.
      _log.warning(LogEvent('upstream request failed', {'path': uri.path}),
          error, stackTrace);
      throw const UpstreamException('the upstream registry is unavailable');
    }
  }
}
