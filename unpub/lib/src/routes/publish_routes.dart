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
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart';

import '../app.dart';
import '../auth/accounts.dart';
import '../auth/auth_middleware.dart';
import '../auth/authenticator.dart';
import '../logging.dart';
import '../models.dart';
import '../package_moderation.dart';
import '../publish_policy.dart';
import '../store/meta_store.dart';
import '../store/object_locks.dart';
import '../upstream/upstream_proxy.dart';
import '../utils.dart';
import '../validation.dart';
import 'responses.dart';
import 'route_support.dart';

final _log = Logger('unpub.app');

/// Room for the multipart framing around an uploaded archive.
const _multipartOverhead = 64 * 1024;

/// An upload that cannot be decided right now, and can be sent again.
class _UploadRetryLater implements Exception {
  final String message;

  const _UploadRetryLater(this.message);

  @override
  String toString() => message;
}

/// `dart pub publish` and the uploaders of a package.
class PublishRoutes {
  final App app;

  /// Uploads being processed in this process, from the first look at the
  /// package to the end. Two uploads of one version could otherwise leave
  /// bytes that do not match the stored hash.
  final _uploadsInProgress = <String>{};

  PublishRoutes(this.app);

  void addRoutes(Router router) {
    router
      ..get('/api/packages/versions/new', getUploadUrl)
      ..post('/api/packages/versions/newUpload', upload)
      ..get('/api/packages/versions/newUploadFinish', uploadFinish)
      ..post('/api/packages/<name>/uploaders', addUploader)
      ..delete('/api/packages/<name>/uploaders/<email>', removeUploader);
  }

  MetaStore get _metaStore => app.metaStore;
  PublishPolicy get _publishPolicy => app.publishPolicy;

  Future<shelf.Response> getUploadUrl(shelf.Request req) async {
    return okWithJson({
      'url': app.resolveUrl(req, '/api/packages/versions/newUpload').toString(),
      'fields': {},
    });
  }

  Future<shelf.Response> upload(shelf.Request req) async {
    final principal = principalOf(req);
    if (principal == null) return unauthenticated();
    final uploader = principal.email;

    String? uploadKey;
    (String, String, String)? reservation;
    try {
      var tarballBytes = await _readUploadedArchive(req);
      var tarBytes = _publishPolicy.inflate(tarballBytes);
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

      var package = await _metaStore.queryPackage(name);
      _checkMayPublish(package, principal, name);

      _publishPolicy.checkName(name);
      _publishPolicy.checkRequiredFiles(archive.files
          .where((file) => file.isFile && !file.isSymbolicLink)
          .map((file) => file.name));
      if (package != null) _publishPolicy.checkVersion(package, version);
      if (package == null) await _rejectUpstreamPackage(name);

      final callback = app.uploadValidator;
      if (callback != null) await callback(pubspec, uploader);

      // The guard above holds in this process only. Taking this before the
      // archive is written keeps other server instances from writing it too.
      final claim = await _metaStore.reserveUpload(name, version);
      if (claim == null) throw PublishPolicy.concurrentPublish(name, version);
      reservation = (name, version, claim);

      // Another server may have finished publishing while the checks ran.
      package = await _metaStore.queryPackage(name);
      _checkMayPublish(package, principal, name);
      if (package != null) _publishPolicy.checkVersion(package, version);

      final previous =
          package?.versions.firstWhereOrNull((item) => item.version == version);
      final archiveHash = sha256.convert(tarballBytes).toString();

      String? readme;
      String? changelog;
      if (readmeFile != null) {
        readme = utf8.decode(readmeFile.content);
      }
      if (changelogFile != null) {
        changelog = utf8.decode(changelogFile.content);
      }

      // Nothing can reach this object until the metadata names its digest, so
      // a publish that stalled past its reservation cannot change an archive.
      // A crash or a lost race leaves an object nothing refers to, which is
      // never deleted here: only reclamation may decide that, under the lock.
      final lock =
          await _lockAndStore(name, version, claim, archiveHash, tarballBytes);
      try {
        if (!await lock.confirm()) {
          throw const _UploadRetryLater(
              'lost the lock on the archive while storing it, try again');
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
          archiveLayout: ArchiveLayout.digest,
        );
        if (previous != null) {
          if (!await _metaStore.replaceVersion(name, unpubVersion,
              expectedSha256: previous.sha256)) {
            throw PublishPolicy.concurrentPublish(name, version);
          }
        } else {
          try {
            await _metaStore.addVersion(name, unpubVersion);
          } on VersionExistsException {
            throw PublishPolicy.duplicateVersion(name, version);
          }
        }
        await _restoreIfGone(name, version, archiveHash, tarballBytes);
      } finally {
        await lock.release();
      }
      await app.audit(req, principal, 'package.published',
          package: name,
          version: version,
          details: {'uploader': uploader, 'sha256': archiveHash});
      app.metrics.publishes++;
      await app.notify(principal, 'package.published',
          package: name,
          version: version,
          data: {'uploader': uploader, 'sha256': archiveHash});

      // TODO: Upload docs
      return shelf.Response.found(
          app.resolveUrl(req, '/api/packages/versions/newUploadFinish'));
    } catch (err, stackTrace) {
      _log.warning(
          LogEvent('upload rejected', {'reason': '$err'}), null, stackTrace);
      return shelf.Response.found(app.resolveUrl(
          req,
          '/api/packages/versions/newUploadFinish'
          '?error=${Uri.encodeQueryComponent('$err')}'
          '${err is _UploadRetryLater ? '&retryable=true' : ''}'));
    } finally {
      if (reservation != null) await _releaseReservation(reservation);
      if (uploadKey != null) _uploadsInProgress.remove(uploadKey);
    }
  }

  /// Takes the lock of [digest] and stores [content] for publishing, and
  /// returns the lock for the caller to keep through its metadata write.
  ///
  /// Waiting for the lock and writing share `publish.uploadTimeout`, so that a
  /// stalled publish fails before its reservation can expire. The reservation
  /// is renewed once, halfway through.
  Future<ObjectLock> _lockAndStore(String name, String version, String claim,
      String digest, List<int> content) async {
    final limit = _publishPolicy.config.uploadTimeout;
    final elapsed = Stopwatch()..start();
    final renewal = Timer(limit ~/ 2, () {
      _metaStore.renewUpload(name, version, claim).then((held) {
        if (!held) {
          _log.warning(LogEvent('an upload reservation expired during a write',
              {'name': name, 'version': version}));
        }
      }, onError: (Object error, StackTrace stackTrace) {
        _log.warning(
            LogEvent('failed to renew an upload reservation',
                {'name': name, 'version': version}),
            error,
            stackTrace);
      });
    });
    ObjectLock? lock;
    try {
      lock = await _metaStore.objectLocks.lock(digest, timeout: limit);
      if (lock == null) {
        throw const _UploadRetryLater('the archive stayed locked for longer '
            'than publish.uploadTimeout, try again');
      }
      try {
        await app.packageStore
            .storeObject(name, version, digest, content)
            .timeout(limit - elapsed.elapsed);
      } on TimeoutException {
        throw const _UploadRetryLater(
            'storing the archive exceeded publish.uploadTimeout, try again');
      }
      return lock;
    } catch (_) {
      await lock?.release();
      rethrow;
    } finally {
      renewal.cancel();
    }
  }

  /// Stores the object again if it disappeared before the metadata was
  /// written, when an identical upload lost or the object looked like an
  /// orphan. A failure is logged and does not fail the publish, which has
  /// already happened.
  Future<void> _restoreIfGone(
      String name, String version, String digest, List<int> content) async {
    final packageStore = app.packageStore;
    try {
      if (await packageStore.objectExists(name, version, digest)) return;
      _log.warning(LogEvent('restoring an archive removed during its publish',
          {'name': name, 'version': version}));
      await packageStore.storeObject(name, version, digest, content);
    } catch (error, stackTrace) {
      _log.severe(
          LogEvent('a published version has no archive in storage',
              {'name': name, 'version': version}),
          error,
          stackTrace);
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
      await _metaStore.releaseUpload(name, version, claim);
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
    final limit = _publishPolicy.maxArchiveBytes;
    final declared = req.contentLength;
    if (declared != null && declared > limit + _multipartOverhead) {
      await req.read().drain<void>();
      throw _publishPolicy.archiveTooLarge();
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
    _publishPolicy.checkSize(size);
    return archive.takeBytes();
  }

  /// Refuses a new package unless the upstream definitely does not have it,
  /// in proxy mode. A package the allowlist keeps from being proxied can be
  /// published here.
  Future<void> _rejectUpstreamPackage(String name) async {
    final proxy = app.upstreamProxy;
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

  Future<shelf.Response> uploadFinish(shelf.Request req) async {
    final query = req.requestedUri.queryParameters;
    final error = query['error'];
    if (error != null) {
      return badRequest(error,
          status: query['retryable'] == 'true'
              ? HttpStatus.serviceUnavailable
              : HttpStatus.badRequest);
    }
    return successMessage('Successfully uploaded package.');
  }

  Future<shelf.Response> addUploader(shelf.Request req, String name) async {
    if (!isValidPackageName(name)) return notFound();

    final principal = principalOf(req);
    if (principal == null) return unauthenticated();

    // A form from `dart pub`, or JSON from the web client.
    String? email;
    final body = await req.readAsString();
    if (req.mimeType == 'application/json') {
      try {
        final decoded = json.decode(body);
        if (decoded is Map && decoded['email'] is String) {
          email = decoded['email'] as String;
        }
      } on FormatException {
        return badRequest('the body must be JSON');
      }
    } else {
      email = Uri.splitQueryString(body)['email'];
    }
    if (email == null) return badRequest('email is required');
    email = normalizeEmail(email);
    if (!isValidEmail(email)) return badRequest('email is invalid');

    return moderationResponse(
        () => PackageModeration(app).addUploader(req, principal, name, email!));
  }

  Future<shelf.Response> removeUploader(
      shelf.Request req, String name, String email) async {
    if (!isValidPackageName(name)) return notFound();

    final principal = principalOf(req);
    if (principal == null) return unauthenticated();

    email = Uri.decodeComponent(email);

    return moderationResponse(() =>
        PackageModeration(app).removeUploader(req, principal, name, email));
  }
}
