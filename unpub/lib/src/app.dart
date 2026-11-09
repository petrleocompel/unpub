import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:collection/collection.dart' show IterableExtension;
import 'package:crypto/crypto.dart' show sha256;
import 'package:http_parser/http_parser.dart';
import 'package:logging/logging.dart';
import 'package:mime/mime.dart';
import 'package:pub_semver/pub_semver.dart' as semver;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_cors_headers/shelf_cors_headers.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:unpub/src/models.dart';
import 'package:unpub/src/store/meta_store.dart';
import 'package:unpub/src/store/package_store.dart';
import 'package:unpub/src/webapi_models.dart';

import 'auth/account_api.dart';
import 'auth/accounts.dart';
import 'auth/auth_middleware.dart';
import 'auth/authenticator.dart';
import 'config/config.dart';
import 'http_cache.dart';
import 'logging.dart';
import 'publish_policy.dart';
import 'redact.dart';
import 'request_logger.dart';
import 'static/index.html.dart' as index_html;
import 'static/main.dart.js.dart' as main_dart_js;
import 'store/audit_store.dart';
import 'upstream/upstream_proxy.dart';
import 'utils.dart';
import 'validation.dart';

part 'app.g.dart';

final _log = Logger('unpub.app');

/// How long a single readiness check may take.
const _healthCheckTimeout = Duration(seconds: 5);

/// Room for the multipart framing around an uploaded archive.
const _multipartOverhead = 64 * 1024;

/// Largest JSON body read by the package management routes.
const _maxJsonBodyBytes = 64 * 1024;

/// Changes when the listing format does, so that a client's validator from an
/// older server does not match.
const _listingFormat = 'listing-v2';

/// An upload that cannot be decided right now, and can be sent again.
class _UploadRetryLater implements Exception {
  final String message;

  const _UploadRetryLater(this.message);

  @override
  String toString() => message;
}

class App {
  /// meta information store
  final MetaStore metaStore;

  /// package(tarball) store
  final PackageStore packageStore;

  /// upstream url, default: https://pub.dev
  final String upstream;

  /// Establishes the identity behind each request.
  final Authenticator authenticator;

  /// Whether reading needs credentials.
  final ReadAccess readAccess;

  /// The account endpoints under `/webapi`, absent when embedding without
  /// user accounts.
  final AccountApi? accountApi;

  /// Records publishes and uploader changes.
  final AuditStore auditStore;

  /// Whether the client address is taken from `X-Forwarded-For`.
  final bool trustForwardedFor;

  /// External URL of this server. When null, URLs derive from the request.
  final Uri? publicUrl;

  /// Fetches packages from the upstream instead of redirecting to it.
  final UpstreamProxy? upstreamProxy;

  /// The `publish` rules uploads must satisfy.
  final PublishPolicy publishPolicy;

  /// validate if the package can be published
  ///
  /// Runs after the [publishPolicy], and only for an upload that passes it.
  final Future<void> Function(
      Map<String, dynamic> pubspec, String uploaderEmail)? uploadValidator;

  /// Uploads being processed in this process, from the first look at the
  /// package to the end. Two uploads of one version could otherwise leave
  /// bytes that do not match the stored hash.
  final _uploadsInProgress = <String>{};

  App({
    required this.metaStore,
    required this.packageStore,
    required this.authenticator,
    this.readAccess = ReadAccess.public,
    this.accountApi,
    this.auditStore = const NullAuditStore(),
    this.trustForwardedFor = false,
    this.upstream = 'https://pub.dev',
    this.upstreamProxy,
    this.publishPolicy = const PublishPolicy(PublishConfig()),
    this.uploadValidator,
    this.publicUrl,
  });

  static shelf.Response _okWithJson(Map<String, dynamic> data,
          {Map<String, String> headers = const {}}) =>
      shelf.Response.ok(
        json.encode(data),
        headers: {
          HttpHeaders.contentTypeHeader: ContentType.json.mimeType,
          'Access-Control-Allow-Origin': '*',
          ...headers,
        },
      );

  static shelf.Response _successMessage(String message) => _okWithJson({
        'success': {'message': message}
      });

  static shelf.Response _badRequest(String message,
          {int status = HttpStatus.badRequest}) =>
      shelf.Response(
        status,
        headers: {HttpHeaders.contentTypeHeader: ContentType.json.mimeType},
        body: json.encode({
          'error': {'message': message}
        }),
      );

  static shelf.Response _notFound([String message = 'Not Found']) =>
      _badRequest(message, status: HttpStatus.notFound);

  static shelf.Response _badGateway(UpstreamException error) =>
      _badRequest(error.message, status: HttpStatus.badGateway);

  /// The version named by a path [segment], or null if it is not one.
  ///
  /// The router passes segments still percent encoded, such as `+` as `%2B`.
  /// Decoding cannot fail, because shelf rejects such requests before routing.
  static String? _parseVersionSegment(String segment) {
    final version = Uri.decodeComponent(segment);
    return isValidPackageVersion(version) ? version : null;
  }

  String _resolveUrl(shelf.Request req, String reference) {
    return (publicUrl ?? req.requestedUri).resolve(reference).toString();
  }

  /// The response for a request that reached a route unauthenticated, which
  /// happens only if the [router] is mounted without [authMiddleware].
  static shelf.Response _unauthenticated() => authFailureResponse(
      const AuthException.unauthorized('Authentication is required.'));

  /// The complete request handler, including all middleware.
  shelf.Handler get handler => const shelf.Pipeline()
      // Bearer tokens work cross-origin, but a session cookie must not: this
      // middleware echoes the origin, so credentialed requests stay disabled.
      .addMiddleware(
          corsHeaders(headers: {'Access-Control-Allow-Credentials': 'false'}))
      .addMiddleware(requestLogger())
      .addMiddleware(authMiddleware(authenticator, readAccess: readAccess))
      .addHandler(router.call);

  Future<HttpServer> serve([String host = '0.0.0.0', int port = 4000]) {
    return shelf_io.serve(handler, host, port);
  }

  Map<String, dynamic> _versionToJson(UnpubVersion item, shelf.Request req) {
    var name = item.pubspec['name'] as String;
    var version = item.version;
    return {
      'archive_url':
          _resolveUrl(req, '/packages/$name/versions/$version.tar.gz'),
      if (item.sha256 != null) 'archive_sha256': item.sha256,
      'pubspec': item.pubspec,
      'version': version,
      'published': item.createdAt.toUtc().toIso8601String(),
      if (item.isRetracted) 'retracted': true,
    };
  }

  bool get _isPublicRead => readAccess == ReadAccess.public;

  /// A validator for a JSON response built from [parts], which also varies
  /// with the origin in its URLs.
  String _listingEtag(shelf.Request req, Iterable<Object?> parts) {
    final input = [_listingFormat, _resolveUrl(req, '/'), ...parts].join('|');
    final digest = sha256.convert(utf8.encode(input)).toString();
    return 'W/"${digest.substring(0, 32)}"';
  }

  /// The validator of the listing of [package].
  ///
  /// Retracting or discontinuing does not touch `updatedAt`, which orders the
  /// package list, so the flags are part of the input.
  String _packageEtag(shelf.Request req, UnpubPackage package) =>
      _listingEtag(req, [
        package.updatedAt.millisecondsSinceEpoch,
        package.isDiscontinued,
        package.replacedBy,
        for (final item in package.versions)
          '${item.version}:${item.isRetracted}:${item.sha256}',
      ]);

  /// [body] as a JSON listing, or a 304 if the client already has [etag].
  shelf.Response _listingResponse(
      shelf.Request req, String etag, Map<String, dynamic> Function() body) {
    final headers = {
      HttpHeaders.etagHeader: etag,
      HttpHeaders.cacheControlHeader:
          _isPublicRead ? 'public, max-age=60' : 'private, no-store',
    };
    if (etagMatches(req.headers[HttpHeaders.ifNoneMatchHeader], etag)) {
      return shelf.Response.notModified(headers: headers);
    }
    return _okWithJson(body(), headers: headers);
  }

  /// The headers of an archive whose hash is [hash], if known.
  Map<String, String> _archiveHeaders(String? hash) => {
        HttpHeaders.cacheControlHeader:
            _isPublicRead ? 'public, max-age=31536000, immutable' : 'private',
        if (hash != null) HttpHeaders.etagHeader: '"$hash"',
      };

  static bool _clientHasArchive(shelf.Request req, String? hash) =>
      hash != null &&
      etagMatches(req.headers[HttpHeaders.ifNoneMatchHeader], '"$hash"');

  /// [version], a listing entry whose `archive_url` is a path on this server,
  /// with that made absolute.
  Map<String, dynamic> _absoluteArchiveUrl(
          shelf.Request req, Map<String, dynamic> version) =>
      {
        ...version,
        'archive_url': _resolveUrl(req, version['archive_url'] as String),
      };

  bool isPubClient(shelf.Request req) {
    var ua = req.headers[HttpHeaders.userAgentHeader];
    return ua != null && ua.toLowerCase().contains('dart pub');
  }

  Router get router {
    final router = _$AppRouter(this);
    accountApi?.addRoutes(router);
    return router;
  }

  Future<void> _audit(
    shelf.Request req,
    Principal principal,
    String action,
    String target, [
    Map<String, Object?> details = const {},
  ]) =>
      auditStore.recordSafely(AuditEvent(
        actor: principal.actor,
        ip: clientAddress(req, trustForwardedFor: trustForwardedFor),
        action: action,
        target: target,
        details: details,
      ));

  @Route.get('/healthz')
  Future<shelf.Response> healthz(shelf.Request req) async {
    return _okWithJson({'status': 'ok'});
  }

  @Route.get('/readyz')
  Future<shelf.Response> readyz(shelf.Request req) async {
    var results = await Future.wait([
      _runCheck(metaStore.checkHealth),
      _runCheck(packageStore.checkHealth),
    ]);
    var checks = {'mongo': results[0], 'storage': results[1]};
    var ready = results.every((result) => result['status'] == 'ok');
    return shelf.Response(
      ready ? HttpStatus.ok : HttpStatus.serviceUnavailable,
      headers: {HttpHeaders.contentTypeHeader: ContentType.json.mimeType},
      body: json.encode({
        'status': ready ? 'ok' : 'unavailable',
        'checks': checks,
      }),
    );
  }

  static Future<Map<String, String>> _runCheck(
      Future<void> Function() check) async {
    try {
      await check().timeout(_healthCheckTimeout);
      return {'status': 'ok'};
    } catch (err) {
      _log.warning('readiness check failed', err);
      return {'status': 'error', 'error': redactConnectionStrings('$err')};
    }
  }

  @Route.get('/api/packages/<name>')
  Future<shelf.Response> getVersions(shelf.Request req, String name) async {
    if (!isValidPackageName(name)) return _notFound();

    final found = await metaStore.queryPackage(name);

    if (found == null) {
      final proxy = upstreamProxy;
      if (proxy != null) return _proxiedListing(req, proxy, name);
      return shelf.Response.found(
          Uri.parse(upstream).resolve('/api/packages/$name').toString());
    }
    final package = found;

    package.versions.sort((a, b) {
      return semver.Version.prioritize(
          semver.Version.parse(a.version), semver.Version.parse(b.version));
    });

    return _listingResponse(req, _packageEtag(req, package), () {
      return {
        'name': name,
        'latest': _versionToJson(package.latest, req),
        'versions':
            package.versions.map((item) => _versionToJson(item, req)).toList(),
        'isDiscontinued': package.isDiscontinued,
        if (package.replacedBy != null) 'replacedBy': package.replacedBy,
      };
    });
  }

  Future<shelf.Response> _proxiedListing(
      shelf.Request req, UpstreamProxy proxy, String name) async {
    if (!proxy.allows(name)) return _notFound();
    final UpstreamListing? listing;
    try {
      listing = await proxy.listing(name);
    } on UpstreamException catch (error) {
      return _badGateway(error);
    }
    if (listing == null) return _notFound();
    final data = listing.json;
    return _listingResponse(req, _listingEtag(req, [listing.digest]), () {
      return {
        ...data,
        if (data['latest'] != null)
          'latest':
              _absoluteArchiveUrl(req, data['latest'] as Map<String, dynamic>),
        'versions': [
          for (final item in data['versions'] as List)
            _absoluteArchiveUrl(req, item as Map<String, dynamic>),
        ],
      };
    });
  }

  @Route.get('/api/packages/<name>/advisories')
  Future<shelf.Response> getAdvisories(shelf.Request req, String name) async {
    if (!isValidPackageName(name)) return _notFound();

    if (await metaStore.queryPackage(name) != null) {
      return _okWithJson({'advisories': [], 'advisoriesUpdated': null});
    }

    final proxy = upstreamProxy;
    if (proxy == null) {
      return shelf.Response.found(Uri.parse(upstream)
          .resolve('/api/packages/$name/advisories')
          .toString());
    }
    if (!proxy.allows(name)) return _notFound();
    final UpstreamDocument? advisories;
    try {
      advisories = await proxy.advisories(name);
    } on UpstreamException catch (error) {
      return _badGateway(error);
    }
    if (advisories == null) return _notFound();
    final document = advisories;
    return _listingResponse(
        req, _listingEtag(req, [document.digest]), () => document.json);
  }

  @Route.get('/api/packages/<name>/versions/<version>')
  Future<shelf.Response> getVersion(
      shelf.Request req, String name, String version) async {
    // Important: + -> %2B, should be decoded here
    var decodedVersion = _parseVersionSegment(version);
    if (!isValidPackageName(name) || decodedVersion == null) return _notFound();
    version = decodedVersion;

    var package = await metaStore.queryPackage(name);
    if (package == null) {
      final proxy = upstreamProxy;
      if (proxy != null) return _proxiedVersion(req, proxy, name, version);
      return shelf.Response.found(Uri.parse(upstream)
          .resolve('/api/packages/$name/versions/$version')
          .toString());
    }

    var packageVersion =
        package.versions.firstWhereOrNull((item) => item.version == version);
    if (packageVersion == null) {
      return shelf.Response.notFound('Not Found');
    }

    final found = packageVersion;
    return _listingResponse(
        req, _packageEtag(req, package), () => _versionToJson(found, req));
  }

  Future<shelf.Response> _proxiedVersion(shelf.Request req, UpstreamProxy proxy,
      String name, String version) async {
    if (!proxy.allows(name)) return _notFound();
    final UpstreamListing? listing;
    try {
      listing = await proxy.listing(name);
    } on UpstreamException catch (error) {
      return _badGateway(error);
    }
    final item = listing?.version(version);
    if (listing == null || item == null) return _notFound();
    return _listingResponse(req, _listingEtag(req, [listing.digest, version]),
        () => _absoluteArchiveUrl(req, item));
  }

  @Route.get('/packages/<name>/versions/<version>.tar.gz')
  Future<shelf.Response> download(
      shelf.Request req, String name, String version) async {
    var decodedVersion = _parseVersionSegment(version);
    if (!isValidPackageName(name) || decodedVersion == null) return _notFound();
    version = decodedVersion;

    var package = await metaStore.queryPackage(name);
    if (package == null) {
      final proxy = upstreamProxy;
      if (proxy != null) return _proxiedDownload(req, proxy, name, version);
      return shelf.Response.found(Uri.parse(upstream)
          .resolve('/packages/$name/versions/$version.tar.gz')
          .toString());
    }

    final packageVersion =
        package.versions.firstWhereOrNull((item) => item.version == version);
    if (packageVersion == null) {
      return _notFound();
    }
    if (!await packageStore.exists(name, version)) {
      _log.warning(LogEvent(
          'archive missing from storage', {'name': name, 'version': version}));
      return _notFound();
    }

    final hash = packageVersion.sha256;
    final headers = _archiveHeaders(hash);
    if (_clientHasArchive(req, hash)) {
      return shelf.Response.notModified(headers: headers);
    }

    if (isPubClient(req) && req.method == 'GET') {
      metaStore.increaseDownloads(name, version);
    }

    if (packageStore.supportsDownloadUrl) {
      return shelf.Response.found(
          await packageStore.downloadUrl(name, version));
    } else {
      return shelf.Response.ok(
        packageStore.download(name, version),
        headers: {
          HttpHeaders.contentTypeHeader: ContentType.binary.mimeType,
          ...headers,
        },
      );
    }
  }

  Future<shelf.Response> _proxiedDownload(shelf.Request req,
      UpstreamProxy proxy, String name, String version) async {
    if (!proxy.allows(name)) return _notFound();

    final known = await proxy.knownSha256(name, version);
    if (_clientHasArchive(req, known)) {
      return shelf.Response.notModified(headers: _archiveHeaders(known));
    }

    final UpstreamArchive? archive;
    try {
      archive = await proxy.archive(name, version);
    } on UpstreamBusyException catch (error) {
      return _badRequest(error.message, status: HttpStatus.serviceUnavailable);
    } on UpstreamException catch (error) {
      return _badGateway(error);
    }
    if (archive == null) return _notFound();
    return shelf.Response.ok(
      archive.content,
      headers: {
        HttpHeaders.contentTypeHeader: ContentType.binary.mimeType,
        ..._archiveHeaders(archive.sha256 ?? known),
      },
    );
  }

  @Route.get('/api/packages/versions/new')
  Future<shelf.Response> getUploadUrl(shelf.Request req) async {
    return _okWithJson({
      'url': _resolveUrl(req, '/api/packages/versions/newUpload').toString(),
      'fields': {},
    });
  }

  @Route.post('/api/packages/versions/newUpload')
  Future<shelf.Response> upload(shelf.Request req) async {
    final principal = principalOf(req);
    if (principal == null) return _unauthenticated();
    final uploader = principal.email;

    String? uploadKey;
    (String, String, String)? reservation;
    try {
      var tarballBytes = await _readUploadedArchive(req);
      var tarBytes = GZipDecoder().decodeBytes(tarballBytes);
      var archive = TarDecoder().decodeBytes(tarBytes);
      ArchiveFile? pubspecArchiveFile;
      ArchiveFile? readmeFile;
      ArchiveFile? changelogFile;

      for (var file in archive.files) {
        if (file.name == 'pubspec.yaml') {
          pubspecArchiveFile = file;
          continue;
        }
        if (file.name.toLowerCase() == 'readme.md') {
          readmeFile = file;
          continue;
        }
        if (file.name.toLowerCase() == 'changelog.md') {
          changelogFile = file;
          continue;
        }
      }

      if (pubspecArchiveFile == null) {
        throw 'Did not find any pubspec.yaml file in upload. Aborting.';
      }

      var pubspecYaml = utf8.decode(pubspecArchiveFile.content);
      var pubspec = loadYamlAsMap(pubspecYaml)!;

      // These reach file paths and object keys, so check them before anything
      // else sees them. The values are not echoed back into the logs.
      final name = pubspec['name'];
      if (name is! String || !isValidPackageName(name)) {
        throw 'Invalid package name: it must match [a-z_][a-z0-9_]* and be at '
            'most $maxPackageNameLength characters long.';
      }
      final version = pubspec['version'];
      if (version is! String || !isValidPackageVersion(version)) {
        throw 'Invalid package version: it must be a semantic version such as '
            '1.2.3.';
      }

      // Serializing here, before reading anything about the package, means an
      // upload cannot act on checks that a concurrent one has outdated.
      final key = '$name@$version';
      if (!_uploadsInProgress.add(key)) {
        throw PublishPolicy.concurrentPublish(name, version);
      }
      uploadKey = key;

      var package = await metaStore.queryPackage(name);
      _checkMayPublish(package, principal, name);

      publishPolicy.checkName(name);
      publishPolicy.checkRequiredFiles(
          archive.files.where((file) => file.isFile).map((file) => file.name));
      if (package != null) publishPolicy.checkVersion(package, version);
      if (package == null) await _rejectUpstreamPackage(name);

      final callback = uploadValidator;
      if (callback != null) await callback(pubspec, uploader);

      // The guard above holds in this process only. Taking this before the
      // archive is written keeps other server instances from writing it too.
      final claim = await metaStore.reserveUpload(name, version);
      if (claim == null) throw PublishPolicy.concurrentPublish(name, version);
      reservation = (name, version, claim);

      // Another server may have finished publishing while the checks ran.
      package = await metaStore.queryPackage(name);
      _checkMayPublish(package, principal, name);
      if (package != null) publishPolicy.checkVersion(package, version);

      final isReplacement =
          package?.versions.any((item) => item.version == version) ?? false;
      final archiveHash = sha256.convert(tarballBytes).toString();

      // Upload package tarball to storage
      await packageStore.upload(name, version, tarballBytes);

      String? readme;
      String? changelog;
      if (readmeFile != null) {
        readme = utf8.decode(readmeFile.content);
      }
      if (changelogFile != null) {
        changelog = utf8.decode(changelogFile.content);
      }

      // Write package meta to database
      var unpubVersion = UnpubVersion(
        version,
        pubspec,
        pubspecYaml,
        uploader,
        readme,
        changelog,
        DateTime.now(),
        sha256: archiveHash,
      );
      if (isReplacement) {
        await metaStore.replaceVersion(name, unpubVersion);
      } else if (!await metaStore.addVersion(name, unpubVersion)) {
        throw PublishPolicy.duplicateVersion(name, version);
      }
      await _audit(req, principal, 'package.published', '$name@$version', {
        'uploader': uploader,
      });

      // TODO: Upload docs
      return shelf.Response.found(
          _resolveUrl(req, '/api/packages/versions/newUploadFinish'));
    } catch (err, stackTrace) {
      _log.warning(
          LogEvent('upload rejected', {'reason': '$err'}), null, stackTrace);
      return shelf.Response.found(_resolveUrl(
          req,
          '/api/packages/versions/newUploadFinish'
          '?error=${Uri.encodeQueryComponent('$err')}'
          '${err is _UploadRetryLater ? '&retryable=true' : ''}'));
    } finally {
      if (reservation != null) await _releaseReservation(reservation);
      if (uploadKey != null) _uploadsInProgress.remove(uploadKey);
    }
  }

  /// Refuses an upload to [package] that [principal] may not make.
  void _checkMayPublish(
      UnpubPackage? package, Principal principal, String name) {
    if (package == null) return;
    if (package.private == false) {
      throw '$name is not a private package. Please upload it to https://pub.dev';
    }
    if (!principal.canChangePackage(package.uploaders)) {
      throw '${principal.email} is not an uploader of $name';
    }
  }

  /// A reservation that cannot be given up expires by itself.
  Future<void> _releaseReservation((String, String, String) reservation) async {
    final (name, version, claim) = reservation;
    try {
      await metaStore.releaseUpload(name, version, claim);
    } catch (error, stackTrace) {
      _log.warning(
          LogEvent('failed to release an upload reservation',
              {'name': name, 'version': version}),
          error,
          stackTrace);
    }
  }

  /// The archive part of a `dart pub publish` request.
  ///
  /// An archive over the limit is not kept in memory, but the body is still
  /// read to its end: closing the connection early would replace the policy
  /// message the client is waiting for with a connection error.
  Future<Uint8List> _readUploadedArchive(shelf.Request req) async {
    final limit = publishPolicy.maxArchiveBytes;
    final declared = req.contentLength;
    if (declared != null && declared > limit + _multipartOverhead) {
      await req.read().drain<void>();
      throw publishPolicy.archiveTooLarge();
    }

    var contentType = req.headers['content-type'];
    if (contentType == null) throw 'invalid content type';

    var mediaType = MediaType.parse(contentType);
    var boundary = mediaType.parameters['boundary'];
    if (boundary == null) throw 'invalid boundary';

    var transformer = MimeMultipartTransformer(boundary);

    // The map below makes the runtime type checker happy.
    // https://github.com/dart-lang/pub-dev/blob/19033f8154ca1f597ef5495acbc84a2bb368f16d/app/lib/fake/server/fake_storage_server.dart#L74
    final stream = req.read().map((a) => a).transform(transformer);
    BytesBuilder? archive;
    var size = 0;
    await for (var part in stream) {
      if (archive != null) {
        await part.drain<void>();
        continue;
      }
      final builder = archive = BytesBuilder(copy: false);
      await for (final chunk in part) {
        size += chunk.length;
        if (size <= limit) {
          builder.add(chunk);
        } else {
          builder.clear();
        }
      }
    }
    if (archive == null) throw 'the upload has no file';
    publishPolicy.checkSize(size);
    return archive.takeBytes();
  }

  /// Refuses a new package unless the upstream definitely does not have it,
  /// in proxy mode. A package the allowlist keeps from being proxied can be
  /// published here.
  Future<void> _rejectUpstreamPackage(String name) async {
    final proxy = upstreamProxy;
    if (proxy == null || !proxy.allows(name)) return;
    final bool exists;
    try {
      exists = await proxy.packageExists(name);
    } on UpstreamException catch (error) {
      if (!proxy.allowPublishWhenUnavailable) {
        throw _UploadRetryLater('upstream registry unavailable, cannot verify '
            'that $name is free, try again');
      }
      _log.warning(LogEvent('publishing without an answer from the upstream',
          {'name': name, 'reason': error.message}));
      return;
    }
    if (exists) {
      throw '$name exists on the upstream registry and is proxied by this '
          'server, so it cannot be published here.';
    }
  }

  @Route.get('/api/packages/versions/newUploadFinish')
  Future<shelf.Response> uploadFinish(shelf.Request req) async {
    final query = req.requestedUri.queryParameters;
    final error = query['error'];
    if (error != null) {
      return _badRequest(error,
          status: query['retryable'] == 'true'
              ? HttpStatus.serviceUnavailable
              : HttpStatus.badRequest);
    }
    return _successMessage('Successfully uploaded package.');
  }

  /// The package when [principal] may manage it, or the response refusing it.
  ///
  /// Only an administrator learns that a package does not exist.
  Future<(UnpubPackage?, shelf.Response?)> _packageForChange(
      String name, Principal principal) async {
    final package = await metaStore.queryPackage(name);
    if (package == null && principal.canPublish && principal.isAdmin) {
      return (null, _notFound());
    }
    if (package == null || !principal.canChangePackage(package.uploaders)) {
      return (null, _badRequest('no permission', status: HttpStatus.forbidden));
    }
    return (package, null);
  }

  @Route.post('/api/packages/<name>/uploaders')
  Future<shelf.Response> addUploader(shelf.Request req, String name) async {
    if (!isValidPackageName(name)) return _notFound();

    final principal = principalOf(req);
    if (principal == null) return _unauthenticated();

    var email = Uri.splitQueryString(await req.readAsString())['email'];
    if (email == null) return _badRequest('email is required');
    email = normalizeEmail(email);
    if (!isValidEmail(email)) return _badRequest('email is invalid');

    final (package, refusal) = await _packageForChange(name, principal);
    if (refusal != null) return refusal;

    if (findEmail(package!.uploaders, email) != null) {
      return _badRequest('email already exists');
    }

    await metaStore.addUploader(name, email);
    await _audit(req, principal, 'uploader.added', name, {'email': email});
    return _successMessage('uploader added');
  }

  @Route.delete('/api/packages/<name>/uploaders/<email>')
  Future<shelf.Response> removeUploader(
      shelf.Request req, String name, String email) async {
    if (!isValidPackageName(name)) return _notFound();

    final principal = principalOf(req);
    if (principal == null) return _unauthenticated();

    email = Uri.decodeComponent(email);

    final (package, refusal) = await _packageForChange(name, principal);
    if (refusal != null) return refusal;

    final stored = findEmail(package!.uploaders, email);
    if (stored == null) return _badRequest('email not uploader');

    await metaStore.removeUploader(name, stored);
    await _audit(req, principal, 'uploader.removed', name, {'email': stored});
    return _successMessage('uploader removed');
  }

  @Route.post('/api/packages/<name>/versions/<version>/retract')
  Future<shelf.Response> retractVersion(
          shelf.Request req, String name, String version) =>
      _changeRetraction(req, name, version, retracted: true);

  @Route.post('/api/packages/<name>/versions/<version>/unretract')
  Future<shelf.Response> unretractVersion(
          shelf.Request req, String name, String version) =>
      _changeRetraction(req, name, version, retracted: false);

  Future<shelf.Response> _changeRetraction(
      shelf.Request req, String name, String version,
      {required bool retracted}) async {
    final decodedVersion = _parseVersionSegment(version);
    if (!isValidPackageName(name) || decodedVersion == null) return _notFound();
    version = decodedVersion;

    final principal = principalOf(req);
    if (principal == null) return _unauthenticated();

    final (package, refusal) = await _packageForChange(name, principal);
    if (refusal != null) return refusal;

    final target =
        package!.versions.firstWhereOrNull((item) => item.version == version);
    if (target == null) return _notFound('version not found');

    final now = DateTime.now();
    if (retracted &&
        !principal.isAdmin &&
        publishPolicy.retractionWindowClosed(target.createdAt, now)) {
      return _badRequest(
          'publish.retractionWindow: $name@$version can no longer be '
          'retracted. Only an administrator can retract it now.',
          status: HttpStatus.forbidden);
    }

    final changed = await metaStore.setVersionRetracted(name, version,
        retracted: retracted,
        retractedAt: retracted ? now : null,
        retractedBy: retracted ? principal.email : null);
    if (changed) {
      await _audit(
        req,
        principal,
        retracted ? 'version.retracted' : 'version.unretracted',
        '$name@$version',
      );
    }
    return _successMessage(
        retracted ? 'version retracted' : 'version restored');
  }

  @Route.put('/api/packages/<name>/discontinue')
  Future<shelf.Response> discontinue(shelf.Request req, String name) async {
    if (!isValidPackageName(name)) return _notFound();

    final principal = principalOf(req);
    if (principal == null) return _unauthenticated();

    final Object? body = await _readJsonBody(req);
    if (body is! Map || body['isDiscontinued'] is! bool) {
      return _badRequest('isDiscontinued must be true or false');
    }
    final discontinued = body['isDiscontinued'] as bool;
    final replacedBy = body['replacedBy'];
    if (replacedBy != null) {
      if (replacedBy is! String || !isValidPackageName(replacedBy)) {
        return _badRequest('replacedBy must be a valid package name');
      }
      if (replacedBy == name) {
        return _badRequest('a package cannot replace itself');
      }
      if (!discontinued) {
        return _badRequest('replacedBy needs isDiscontinued to be true');
      }
    }

    final (package, refusal) = await _packageForChange(name, principal);
    if (refusal != null) return refusal;

    final wasDiscontinued = package!.isDiscontinued;
    await metaStore.setDiscontinued(
      name,
      discontinued: discontinued,
      replacedBy: replacedBy as String?,
      discontinuedAt: discontinued
          ? (wasDiscontinued ? package.discontinuedAt : null) ?? DateTime.now()
          : null,
    );
    await _audit(
      req,
      principal,
      discontinued ? 'package.discontinued' : 'package.continued',
      name,
      {if (replacedBy != null) 'replacedBy': replacedBy},
    );
    return _successMessage(
        discontinued ? 'package discontinued' : 'package continued');
  }

  /// The JSON value of the request body, or null if it is too large or not
  /// valid JSON.
  static Future<Object?> _readJsonBody(shelf.Request req) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in req.read()) {
      bytes.add(chunk);
      if (bytes.length > _maxJsonBodyBytes) return null;
    }
    try {
      return json.decode(utf8.decode(bytes.takeBytes()));
    } on FormatException {
      return null;
    }
  }

  @Route.get('/webapi/packages')
  Future<shelf.Response> getPackages(shelf.Request req) async {
    var params = req.requestedUri.queryParameters;
    var size = int.tryParse(params['size'] ?? '') ?? 10;
    var page = int.tryParse(params['page'] ?? '') ?? 0;
    var sort = params['sort'] ?? 'download';
    var q = params['q'];

    String? keyword;
    String? uploader;
    String? dependency;

    if (q == null) {
    } else if (q.startsWith('email:')) {
      uploader = q.substring(6).trim();
    } else if (q.startsWith('dependency:')) {
      dependency = q.substring(11).trim();
    } else {
      keyword = q;
    }

    final result = await metaStore.queryPackages(
      size: size,
      page: page,
      sort: sort,
      keyword: keyword,
      uploader: uploader,
      dependency: dependency,
      includeDiscontinued: params['discontinued'] == 'true',
    );

    var data = ListApi(result.count, [
      for (var package in result.packages)
        ListApiPackage(
          package.name,
          package.latest.pubspec['description'] as String?,
          getPackageTags(package.latest.pubspec),
          package.latest.version,
          package.updatedAt,
          isDiscontinued: package.isDiscontinued,
          replacedBy: package.replacedBy,
        )
    ]);

    return _okWithJson({'data': data.toJson()});
  }

  @Route.get('/packages/<name>.json')
  Future<shelf.Response> getPackageVersions(
      shelf.Request req, String name) async {
    if (!isValidPackageName(name)) return _notFound();

    var package = await metaStore.queryPackage(name);
    if (package == null) {
      return _badRequest('package not exists', status: HttpStatus.notFound);
    }

    var versions = package.versions.map((v) => v.version).toList();
    versions.sort((a, b) {
      return semver.Version.prioritize(
          semver.Version.parse(b), semver.Version.parse(a));
    });

    return _okWithJson({
      'name': name,
      'versions': versions,
    });
  }

  @Route.get('/webapi/package/<name>/<version>')
  Future<shelf.Response> getPackageDetail(
      shelf.Request req, String name, String version) async {
    if (!isValidPackageName(name)) return _notFound();
    if (version != 'latest') {
      var decodedVersion = _parseVersionSegment(version);
      if (decodedVersion == null) return _notFound();
      version = decodedVersion;
    }

    var package = await metaStore.queryPackage(name);
    if (package == null) {
      return _okWithJson({'error': 'package not exists'});
    }

    UnpubVersion? packageVersion;
    if (version == 'latest') {
      packageVersion = package.latest;
    } else {
      packageVersion =
          package.versions.firstWhereOrNull((item) => item.version == version);
    }
    if (packageVersion == null) {
      return _okWithJson({'error': 'version not exists'});
    }

    var versions = package.versions
        .map((v) => DetailViewVersion(v.version, v.createdAt,
            isRetracted: v.isRetracted))
        .toList();
    versions.sort((a, b) {
      return semver.Version.prioritize(
          semver.Version.parse(b.version), semver.Version.parse(a.version));
    });

    var pubspec = packageVersion.pubspec;
    List<String?> authors;
    if (pubspec['author'] != null) {
      authors = RegExp(r'<(.*?)>')
          .allMatches(pubspec['author'])
          .map((match) => match.group(1))
          .toList();
    } else if (pubspec['authors'] != null) {
      authors = (pubspec['authors'] as List)
          .map((author) => RegExp(r'<(.*?)>').firstMatch(author)!.group(1))
          .toList();
    } else {
      authors = [];
    }

    var depMap = (pubspec['dependencies'] as Map? ?? {}).cast<String, String>();

    var data = WebapiDetailView(
      package.name,
      packageVersion.version,
      packageVersion.pubspec['description'] ?? '',
      packageVersion.pubspec['homepage'] ?? '',
      package.uploaders ?? [],
      packageVersion.createdAt,
      packageVersion.readme,
      packageVersion.changelog,
      versions,
      authors,
      depMap.keys.toList(),
      getPackageTags(packageVersion.pubspec),
      isRetracted: packageVersion.isRetracted,
      retractedAt: packageVersion.retractedAt,
      isDiscontinued: package.isDiscontinued,
      replacedBy: package.replacedBy,
      downloads: {
        'version':
            await metaStore.versionDownloads(name, packageVersion.version),
        'package': package.download ?? 0,
      },
    );

    return _okWithJson({'data': data.toJson()});
  }

  @Route.get('/')
  @Route.get('/packages')
  @Route.get('/packages/<name>')
  @Route.get('/packages/<name>/versions/<version>')
  Future<shelf.Response> indexHtml(shelf.Request req) async {
    return shelf.Response.ok(index_html.content,
        headers: {HttpHeaders.contentTypeHeader: ContentType.html.mimeType});
  }

  @Route.get('/main.dart.js')
  Future<shelf.Response> mainDartJs(shelf.Request req) async {
    return shelf.Response.ok(main_dart_js.content,
        headers: {HttpHeaders.contentTypeHeader: 'text/javascript'});
  }

  String _getBadgeUrl(String label, String message, String color,
      Map<String, String> queryParameters) {
    var badgeUri = Uri.parse('https://img.shields.io/static/v1');
    return Uri(
        scheme: badgeUri.scheme,
        host: badgeUri.host,
        path: badgeUri.path,
        queryParameters: {
          'label': label,
          'message': message,
          'color': color,
          ...queryParameters,
        }).toString();
  }

  @Route.get('/badge/<type>/<name>')
  Future<shelf.Response> badge(
      shelf.Request req, String type, String name) async {
    if (!isValidPackageName(name)) return _notFound();

    var queryParameters = req.requestedUri.queryParameters;
    var package = await metaStore.queryPackage(name);
    if (package == null) {
      return shelf.Response.notFound('Not found');
    }

    switch (type) {
      case 'v':
        var latest = semver.Version.parse(package.latest.version);

        var color = latest.major == 0 ? 'orange' : 'blue';

        return shelf.Response.found(
            _getBadgeUrl('unpub', latest.toString(), color, queryParameters));
      case 'd':
        return shelf.Response.found(_getBadgeUrl(
            'downloads', package.download.toString(), 'blue', queryParameters));
      default:
        return shelf.Response.notFound('Not found');
    }
  }
}
