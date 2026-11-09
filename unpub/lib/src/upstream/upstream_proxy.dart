import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show Digest, sha256;
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../config/config.dart';
import '../logging.dart';
import '../pub_listing.dart';
import '../store/object_locks.dart';
import '../store/package_store.dart';
import '../store/upstream_cache_store.dart';
import '../validation.dart';
import '../version.dart';

final _log = Logger('unpub.upstream');

/// Largest metadata response read from the upstream.
const _maxMetadataBytes = 64 * 1024 * 1024;

/// How long past `cacheTtl` an entry stays, for revalidation and so that a
/// cached archive keeps its validator.
const _staleRetention = Duration(days: 7);

/// How many redirects one upstream request may follow.
const _maxRedirects = 3;

/// How long a fetched archive the store did not keep stays on disk. Clients
/// that were waiting open it right away, and a file that is open can still be
/// read after it is deleted.
const _unkeptArchiveLifetime = Duration(seconds: 30);

const _pubAccept = 'application/vnd.pub.v2+json';
final _userAgent = 'unpub/$packageVersion '
    '(+https://github.com/petrleocompel/unpub)';
final _sha256Pattern = RegExp(r'^[0-9a-fA-F]{64}$');

/// The upstream could not give a usable answer.
class UpstreamException implements Exception {
  final String message;

  const UpstreamException(this.message);

  @override
  String toString() => message;
}

/// Every fetch slot stayed taken for as long as the request may wait.
class UpstreamBusyException extends UpstreamException {
  const UpstreamBusyException()
      : super('too many upstream downloads are running, try again');
}

/// A package listing from the upstream, ready to serve.
class UpstreamListing {
  /// The pub API response, with `archive_url` as a path on this server.
  final Map<String, dynamic> json;

  /// The upstream URL of each version's archive.
  final Map<String, String> archiveUrls;

  /// Changes whenever the listing does.
  final String digest;

  /// Versions whose hash the upstream sent in a form that is not a SHA-256.
  /// Their entries in [json] carry no hash, and they cannot be fetched.
  final Set<String> invalidHashes;

  const UpstreamListing(this.json, this.archiveUrls, this.digest,
      [this.invalidHashes = const {}]);

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

  /// Lowercase hex SHA-256 of the bytes in [content].
  final String digest;

  /// Whether [digest] matched a hash published by the upstream.
  final bool verified;

  const UpstreamArchive(this.content, this.digest, {required this.verified});

  /// Weak for bytes no hash from the upstream vouches for.
  String get etag => verified ? '"$digest"' : 'W/"$digest"';
}

/// A fetched archive, kept in the store or else still in [spool].
class _FetchedArchive {
  final File? spool;
  final String digest;
  final bool verified;

  const _FetchedArchive(this.spool, this.digest, {required this.verified});
}

/// Limits how many archives are fetched at once.
class _FetchSlots {
  int _free;
  final _waiting = Queue<Completer<void>>();

  _FetchSlots(this._free);

  /// Takes a slot, waiting at most [patience] for one.
  Future<void> acquire(Duration patience) async {
    if (_free > 0) {
      _free--;
      return;
    }
    final waiter = Completer<void>();
    _waiting.add(waiter);
    try {
      await waiter.future.timeout(patience);
    } on TimeoutException {
      _waiting.remove(waiter);
      throw const UpstreamBusyException();
    }
  }

  void release() {
    if (_waiting.isEmpty) {
      _free++;
    } else {
      _waiting.removeFirst().complete();
    }
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
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
  final bool requireSha256;
  final bool allowPublishWhenUnavailable;
  final int maxArchiveBytes;
  final http.Client _client;
  final DateTime Function() clock;

  final _inFlight = <String, Future<Object?>>{};
  final _unkeptArchives = <File, Timer>{};
  final _FetchSlots _slots;

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
        requireSha256 = config.requireSha256,
        allowPublishWhenUnavailable = config.allowPublishWhenUnavailable,
        maxArchiveBytes = config.maxArchiveBytes,
        _slots = _FetchSlots(config.maxConcurrentFetches),
        _client = client ?? http.Client();

  void close() {
    _client.close();
    for (final entry in _unkeptArchives.entries) {
      entry.value.cancel();
      try {
        entry.key.deleteSync();
      } on FileSystemException {
        // Already gone.
      }
    }
    _unkeptArchives.clear();
  }

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

  /// Whether the upstream has [name]: a fresh listing says so without asking,
  /// and anything else takes an answer from the upstream.
  ///
  /// Throws an [UpstreamException] if the upstream gives no definitive answer.
  Future<bool> packageExists(String name) async => await listing(name) != null;

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

    final (body, urls, invalidHashes) = _rewriteListing(name, response.body!);
    final fetchedAt = clock();
    await _store(UpstreamCacheEntry(
      key: name,
      body: body,
      archiveUrls: json.encode(urls),
      invalidHashes: invalidHashes.toList(),
      etag: response.etag,
      fetchedAt: fetchedAt,
    ));
    return UpstreamListing(json.decode(body) as Map<String, dynamic>, urls,
        _digest(body), invalidHashes);
  }

  UpstreamListing _decodeCached(UpstreamCacheEntry entry) => UpstreamListing(
        json.decode(entry.body) as Map<String, dynamic>,
        (json.decode(entry.archiveUrls ?? '{}') as Map).cast<String, String>(),
        _digest(entry.body),
        entry.invalidHashes.toSet(),
      );

  static String _digest(String body) =>
      sha256.convert(utf8.encode(body)).toString();

  /// Keeps only the fields of the pub API, and points archives at this server.
  ///
  /// The cached form uses paths rather than absolute URLs. An absolute URL
  /// would hold the `Host` of whichever request came first, for every client.
  (String, Map<String, String>, Set<String>) _rewriteListing(
      String name, Uint8List body) {
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
    final invalidHashes = <String>{};
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
      final isValidHash = hash is String && _sha256Pattern.hasMatch(hash);
      if (hash != null && !isValidHash) invalidHashes.add(version);
      return pubVersionJson(
        archiveUrl: archivePath(name, version),
        archiveSha256: isValidHash ? hash.toLowerCase() : null,
        pubspec: item['pubspec'],
        version: version,
        published: item['published'],
        retracted: item['retracted'] == true,
      );
    }

    final versions =
        (decoded['versions'] as List).map(rewrite).nonNulls.toList();
    if (versions.isEmpty) {
      throw const UpstreamException('the upstream listing has no versions');
    }
    final latest = rewrite(decoded['latest']);
    final result = json.encode(pubPackageJson(
      name: name,
      latest: latest,
      versions: versions,
      isDiscontinued: decoded['isDiscontinued'] == true,
      replacedBy:
          decoded['replacedBy'] is String ? decoded['replacedBy'] : null,
      advisoriesUpdated: decoded['advisoriesUpdated'],
    ));
    return (result, urls, invalidHashes);
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

  /// The hash a client with this archive would hold, without asking the
  /// upstream: what the listing says, or else what is still kept.
  Future<String?> knownSha256(String name, String version) async {
    final listed = (await _cachedListing(name))?.sha256Of(version);
    if (listed != null) return listed;
    final record = await cache.readArchive(name, version);
    if (record == null || !record.verified) return null;
    return await _isStored(name, version, record.sha256) ? record.sha256 : null;
  }

  Future<UpstreamListing?> _cachedListing(String name) async {
    final cached = await cache.read(name);
    return cached == null ? null : _decodeCached(cached);
  }

  /// The archive of [name] [version], from the store if it is there and
  /// otherwise fetched, verified and stored.
  ///
  /// The archive is fetched completely, to a temporary file, before the client
  /// gets a byte, because only then can a corrupt archive still be answered
  /// with an error status. Returns null if the upstream does not have it.
  ///
  /// Throws an [UpstreamException] if it cannot be fetched or fails to verify,
  /// and specifically an [UpstreamBusyException] if too many are being fetched.
  Future<UpstreamArchive?> archive(String name, String version) async {
    final kept = await _keptArchive(name, version);
    if (kept != null) return kept;
    final fetched = await _once(
        'archive:$name@$version', () => _fetchArchive(name, version));
    if (fetched == null) return null;
    return UpstreamArchive(
        fetched.spool?.openRead() ??
            archives.downloadUpstream(name, version, fetched.digest),
        fetched.digest,
        verified: fetched.verified);
  }

  /// The archive the record points to, if it can be served as it is.
  ///
  /// With no record, or no object under the digest it names, there is nothing
  /// cached. A copy the current listing no longer agrees with is left for
  /// fetching again.
  Future<UpstreamArchive?> _keptArchive(String name, String version) async {
    final record = await cache.readArchive(name, version);
    if (record == null) return null;
    if (!await _isStored(name, version, record.sha256)) return null;

    final listing = await _cachedListing(name);
    if (listing?.invalidHashes.contains(version) ?? false) return null;
    final listed = listing?.sha256Of(version);
    if (listed != null && listed != record.sha256) {
      _log.warning(LogEvent('cached archive differs from the upstream listing',
          {'name': name, 'version': version}));
      return null;
    }
    final isVerified = listed != null || record.verified;
    if (!isVerified && requireSha256) return null;
    return UpstreamArchive(
        archives.downloadUpstream(name, version, record.sha256), record.sha256,
        verified: isVerified);
  }

  /// A store that cannot be read is treated as not holding the archive, so
  /// that the upstream can still serve it.
  Future<bool> _isStored(String name, String version, String digest) async {
    try {
      return await archives.upstreamCached(name, version, digest);
    } catch (error, stackTrace) {
      _log.warning(
          LogEvent('failed to look up cached archive',
              {'name': name, 'version': version}),
          error,
          stackTrace);
      return false;
    }
  }

  Future<_FetchedArchive?> _fetchArchive(String name, String version) =>
      _guarded('/packages/$name/versions/$version', () async {
        final metadata = await listing(name);
        final archiveUrl = metadata?.archiveUrls[version];
        if (metadata == null || archiveUrl == null) return null;

        if (metadata.invalidHashes.contains(version)) {
          _log.warning(LogEvent('upstream sent a malformed archive hash',
              {'name': name, 'version': version}));
          throw const UpstreamException(
              'upstream provided an invalid archive_sha256');
        }
        final expected = metadata.sha256Of(version);
        if (expected == null && requireSha256) {
          throw UpstreamException(
              'upstream provides no archive_sha256 for $name $version');
        }

        await _forgetIfDifferent(name, version, expected);

        await _slots.acquire(timeout);
        try {
          return await _download(
              name, version, Uri.parse(archiveUrl), expected);
        } finally {
          _slots.release();
        }
      });

  /// Fetches the archive into a temporary file, and hands it to the store only
  /// once it has passed verification. No failure leaves the file behind.
  Future<_FetchedArchive?> _download(
      String name, String version, Uri uri, String? expected) async {
    final temporary = await archives.upstreamTemporaryFile(name, version);
    try {
      final response = await _send(uri);
      if (response.statusCode == 404) {
        await _discard(response);
        await _delete(temporary);
        return null;
      }
      if (response.statusCode != 200) {
        await _discard(response);
        _log.warning(LogEvent('upstream refused a request',
            {'status': response.statusCode, 'path': uri.path}));
        throw const UpstreamException(
            'the upstream registry refused the request');
      }
      final (actual, size) = await _spool(response, temporary);
      if (expected == null) {
        _log.warning(LogEvent('serving an upstream archive without a hash',
            {'name': name, 'version': version}));
      } else if (actual != expected) {
        _log.warning(LogEvent('upstream archive failed verification',
            {'name': name, 'version': version}));
        throw const UpstreamException(
            'the upstream archive did not match its published hash');
      }

      final verified = expected != null;
      if (await _keep(name, version, temporary, size, actual,
          verified: verified)) {
        await _delete(temporary);
        return _FetchedArchive(null, actual, verified: verified);
      }
      _expire(temporary);
      return _FetchedArchive(temporary, actual, verified: verified);
    } catch (_) {
      await _delete(temporary);
      rethrow;
    }
  }

  /// Writes the body of [response] to [file], and returns its hash and size.
  /// Fails as soon as the body passes [maxArchiveBytes].
  Future<(String, int)> _spool(
      http.StreamedResponse response, File file) async {
    if ((response.contentLength ?? 0) > maxArchiveBytes) {
      await response.stream.listen(null).cancel();
      throw const UpstreamException(_archiveTooLarge);
    }
    final digest = _DigestSink();
    final hasher = sha256.startChunkedConversion(digest);
    final output = await file.open(mode: FileMode.writeOnly);
    var size = 0;
    try {
      await for (final chunk in response.stream.timeout(timeout)) {
        size += chunk.length;
        if (size > maxArchiveBytes) {
          throw const UpstreamException(_archiveTooLarge);
        }
        hasher.add(chunk);
        await output.writeFrom(chunk);
      }
    } finally {
      await output.close();
    }
    hasher.close();
    return (digest.value.toString(), size);
  }

  static const _archiveTooLarge =
      'the upstream archive is larger than upstream.maxArchiveBytes';

  /// Hands a verified archive to the store and records it, and returns whether
  /// the store has it. A store that fails does not fail the download, because
  /// the client can still have the verified archive.
  ///
  /// Both happen under the lock of the digest, so that reclamation cannot take
  /// the object between them.
  Future<bool> _keep(
      String name, String version, File temporary, int size, String digest,
      {required bool verified}) async {
    final event = {'name': name, 'version': version};
    final ObjectLock? lock;
    try {
      lock = await cache.objectLocks.lock(digest, timeout: timeout);
    } catch (error, stackTrace) {
      _log.warning(LogEvent('failed to lock upstream archive', event), error,
          stackTrace);
      return false;
    }
    if (lock == null) {
      _log.warning(
          LogEvent('upstream archive stayed locked, not keeping it', event));
      return false;
    }
    try {
      return await _commit(name, version, temporary, size, digest,
          verified: verified, event: event);
    } finally {
      await lock.release();
    }
  }

  Future<bool> _commit(
      String name, String version, File temporary, int size, String digest,
      {required bool verified, required Map<String, Object> event}) async {
    try {
      if (!await archives.commitUpstream(
          name, version, digest, temporary, size)) {
        return false;
      }
    } catch (error, stackTrace) {
      _log.warning(LogEvent('failed to store upstream archive', event), error,
          stackTrace);
      return false;
    }
    try {
      await cache.writeArchive(UpstreamArchiveRecord(
        name: name,
        version: version,
        sha256: digest,
        bytes: size,
        fetchedAt: clock(),
        verified: verified,
      ));
    } catch (error, stackTrace) {
      // The record still names the previous object, if any, whose bytes still
      // match it. Without one the archive is fetched again next time.
      _log.warning(LogEvent('failed to record upstream archive', event), error,
          stackTrace);
    }
    return true;
  }

  static Future<void> _delete(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      // Moved into the store, or never created.
    }
  }

  void _expire(File file) {
    _unkeptArchives[file] = Timer(_unkeptArchiveLifetime, () {
      _unkeptArchives.remove(file);
      _delete(file);
    });
  }

  /// Throws away a kept copy whose hash is not [expected], so that it cannot
  /// be served again whatever happens to the fetch that replaces it.
  Future<void> _forgetIfDifferent(
      String name, String version, String? expected) async {
    final record = await cache.readArchive(name, version);
    if (record == null || expected == null || record.sha256 == expected) return;
    await cache.deleteArchive(name, version);
    final lock = await cache.objectLocks.tryLock(record.sha256);
    // Reclamation gets the object later, if something else is using it now.
    if (lock == null) return;
    try {
      final current = await cache.readArchive(name, version);
      if (current?.sha256 != record.sha256) {
        await archives.deleteUpstream(name, version, record.sha256);
      }
    } finally {
      await lock.release();
    }
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

  /// Runs [action], turning every failure into an [UpstreamException] that
  /// says nothing about the upstream's internals, logged here.
  Future<T> _guarded<T>(String path, Future<T> Function() action) async {
    try {
      return await action();
    } on UpstreamException {
      rethrow;
    } catch (error, stackTrace) {
      // TimeoutException, SocketException, http.ClientException and so on.
      _log.warning(LogEvent('upstream request failed', {'path': path}), error,
          stackTrace);
      throw const UpstreamException('the upstream registry is unavailable');
    }
  }

  /// Returns null for a 404, and throws an [UpstreamException] otherwise.
  Future<_Response?> _get(Uri uri, int limit, {String? accept, String? etag}) =>
      _guarded(uri.path, () async {
        final response = await _send(uri, accept: accept, etag: etag);
        if (response.statusCode == 304) {
          await _discard(response);
          // Only a validator from the cache can be answered with a 304, so
          // without one there is nothing it could refer to.
          if (etag == null) {
            _log.warning(LogEvent(
                'upstream sent an unrequested 304', {'path': uri.path}));
            throw const UpstreamException(
                'the upstream sent a 304 for a request that had no validator');
          }
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
      });
}
