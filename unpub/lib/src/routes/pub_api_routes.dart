import 'dart:io';

import 'package:collection/collection.dart' show IterableExtension;
import 'package:crypto/crypto.dart' show sha256;
import 'package:logging/logging.dart';
import 'package:pub_semver/pub_semver.dart' as semver;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart';

import '../app.dart';
import '../http_cache.dart';
import '../logging.dart';
import '../models.dart';
import '../pub_listing.dart';
import '../store/package_store.dart';
import '../upstream/upstream_proxy.dart';
import '../validation.dart';
import 'responses.dart';
import 'route_support.dart';

final _log = Logger('unpub.app');

/// The read side of the pub API: listings, versions, archives and advisories.
class PubApiRoutes {
  final App app;

  PubApiRoutes(this.app);

  void addRoutes(Router router) {
    router
      ..get('/api/packages/<name>', getVersions)
      ..get('/api/packages/<name>/advisories', getAdvisories)
      ..get('/api/packages/<name>/versions/<version>', getVersion)
      ..get('/packages/<name>/versions/<version>.tar.gz', download);
  }

  Future<shelf.Response> getVersions(shelf.Request req, String name) async {
    if (!isValidPackageName(name)) return notFound();

    final found = await app.metaStore.queryPackage(name);

    if (found == null) {
      final proxy = app.upstreamProxy;
      if (proxy != null) return _proxiedListing(req, proxy, name);
      return shelf.Response.found(
          Uri.parse(app.upstream).resolve('/api/packages/$name').toString());
    }
    final package = found;

    package.versions.sort((a, b) {
      return semver.Version.prioritize(
          semver.Version.parse(a.version), semver.Version.parse(b.version));
    });

    return app.listingResponse(req, app.packageEtag(req, package), () {
      return pubPackageJson(
        name: name,
        latest: app.versionToJson(package.latest, req),
        versions: package.versions
            .map((item) => app.versionToJson(item, req))
            .toList(),
        isDiscontinued: package.isDiscontinued,
        replacedBy: package.replacedBy,
      );
    });
  }

  Future<shelf.Response> _proxiedListing(
      shelf.Request req, UpstreamProxy proxy, String name) async {
    if (!proxy.allows(name)) return notFound();
    final UpstreamListing? listing;
    try {
      listing = await proxy.listing(name);
    } on UpstreamException catch (error) {
      return badGateway(error);
    }
    if (listing == null) return notFound();
    final data = listing.json;
    return app.listingResponse(req, app.listingEtag(req, [listing.digest]), () {
      return pubPackageJson(
        name: name,
        latest: data['latest'] == null
            ? null
            : app.absoluteArchiveUrl(
                req, data['latest'] as Map<String, dynamic>),
        versions: [
          for (final item in data['versions'] as List)
            app.absoluteArchiveUrl(req, item as Map<String, dynamic>),
        ],
        isDiscontinued: data['isDiscontinued'] as bool,
        replacedBy: data['replacedBy'],
        advisoriesUpdated: data['advisoriesUpdated'],
      );
    });
  }

  Future<shelf.Response> getAdvisories(shelf.Request req, String name) async {
    if (!isValidPackageName(name)) return notFound();

    if (await app.metaStore.queryPackage(name) != null) {
      return okWithJson({'advisories': [], 'advisoriesUpdated': null});
    }

    final proxy = app.upstreamProxy;
    if (proxy == null) {
      return shelf.Response.found(Uri.parse(app.upstream)
          .resolve('/api/packages/$name/advisories')
          .toString());
    }
    if (!proxy.allows(name)) return notFound();
    final UpstreamDocument? advisories;
    try {
      advisories = await proxy.advisories(name);
    } on UpstreamException catch (error) {
      return badGateway(error);
    }
    if (advisories == null) return notFound();
    final document = advisories;
    return app.listingResponse(
        req, app.listingEtag(req, [document.digest]), () => document.json);
  }

  Future<shelf.Response> getVersion(
      shelf.Request req, String name, String version) async {
    // Important: + -> %2B, should be decoded here
    var decodedVersion = parseVersionSegment(version);
    if (!isValidPackageName(name) || decodedVersion == null) return notFound();
    version = decodedVersion;

    var package = await app.metaStore.queryPackage(name);
    if (package == null) {
      final proxy = app.upstreamProxy;
      if (proxy != null) return _proxiedVersion(req, proxy, name, version);
      return shelf.Response.found(Uri.parse(app.upstream)
          .resolve('/api/packages/$name/versions/$version')
          .toString());
    }

    var packageVersion =
        package.versions.firstWhereOrNull((item) => item.version == version);
    if (packageVersion == null) {
      return shelf.Response.notFound('Not Found');
    }

    final found = packageVersion;
    return app.listingResponse(req, app.packageEtag(req, package),
        () => app.versionToJson(found, req));
  }

  Future<shelf.Response> _proxiedVersion(shelf.Request req, UpstreamProxy proxy,
      String name, String version) async {
    if (!proxy.allows(name)) return notFound();
    final UpstreamListing? listing;
    try {
      listing = await proxy.listing(name);
    } on UpstreamException catch (error) {
      return badGateway(error);
    }
    final item = listing?.version(version);
    if (listing == null || item == null) return notFound();
    return app.listingResponse(
        req,
        app.listingEtag(req, [listing.digest, version]),
        () => app.absoluteArchiveUrl(req, item));
  }

  Future<shelf.Response> download(
      shelf.Request req, String name, String version) async {
    var decodedVersion = parseVersionSegment(version);
    if (!isValidPackageName(name) || decodedVersion == null) return notFound();
    version = decodedVersion;

    final metaStore = app.metaStore;
    final packageStore = app.packageStore;
    var package = await metaStore.queryPackage(name);
    if (package == null) {
      final proxy = app.upstreamProxy;
      if (proxy != null) return _proxiedDownload(req, proxy, name, version);
      return shelf.Response.found(Uri.parse(app.upstream)
          .resolve('/packages/$name/versions/$version.tar.gz')
          .toString());
    }

    final packageVersion =
        package.versions.firstWhereOrNull((item) => item.version == version);
    if (packageVersion == null) {
      return notFound();
    }
    final hash = packageVersion.sha256;
    final String? object;
    if (await _isStoredAsObject(name, packageVersion)) {
      // Never the legacy path: bytes from there would go out under the digest
      // of another archive.
      if (hash == null ||
          !PackageStore.isDigest(hash) ||
          !await packageStore.objectExists(name, version, hash)) {
        _log.severe(LogEvent('archive object missing from storage',
            {'name': name, 'version': version, 'digest': hash ?? 'none'}));
        return notFound();
      }
      object = hash;
    } else {
      if (!await packageStore.exists(name, version)) {
        _log.warning(LogEvent('archive missing from storage',
            {'name': name, 'version': version}));
        return notFound();
      }
      if (packageVersion.archiveLayout == null &&
          hash != null &&
          PackageStore.isDigest(hash) &&
          !await _legacyArchiveMatches(name, version, hash)) {
        // A version from before layouts were recorded whose digest object is
        // gone: the legacy file may belong to an earlier archive of the same
        // version, and must not go out under this digest.
        _log.severe(LogEvent(
            'legacy archive does not match the recorded digest',
            {'name': name, 'version': version, 'digest': hash}));
        return notFound();
      }
      object = null;
    }

    final headers = app.archiveHeaders(hash);
    if (clientHasArchive(req, hash)) {
      return shelf.Response.notModified(headers: headers);
    }

    if (app.isPubClient(req) && req.method == 'GET') {
      metaStore.increaseDownloads(name, version);
      app.metrics.downloads++;
    }

    if (packageStore.supportsDownloadUrl) {
      return shelf.Response.found(object == null
          ? await packageStore.downloadUrl(name, version)
          : await packageStore.objectDownloadUrl(name, version, object));
    } else {
      return shelf.Response.ok(
        object == null
            ? packageStore.download(name, version)
            : packageStore.downloadObject(name, version, object),
        headers: {
          HttpHeaders.contentTypeHeader: ContentType.binary.mimeType,
          ...headers,
        },
      );
    }
  }

  /// Whether the file at the legacy path of this version hashes to [digest].
  Future<bool> _legacyArchiveMatches(
      String name, String version, String digest) async {
    try {
      final actual =
          await sha256.bind(app.packageStore.download(name, version)).first;
      return actual.toString() == digest;
    } catch (error, stackTrace) {
      _log.warning(
          LogEvent(
              'cannot hash legacy archive', {'name': name, 'version': version}),
          error,
          stackTrace);
      return false;
    }
  }

  /// Whether [item] is an object named by its digest, rather than a file at
  /// the mutable path. A version from before layouts were recorded has a digest
  /// object if one exists, or if there is no legacy file either.
  Future<bool> _isStoredAsObject(String name, UnpubVersion item) async {
    if (item.archiveLayout == ArchiveLayout.digest) return true;
    if (item.archiveLayout == ArchiveLayout.legacy) return false;
    final hash = item.sha256;
    if (hash == null || !PackageStore.isDigest(hash)) return false;
    return await app.packageStore.objectExists(name, item.version, hash) ||
        !await app.packageStore.exists(name, item.version);
  }

  Future<shelf.Response> _proxiedDownload(shelf.Request req,
      UpstreamProxy proxy, String name, String version) async {
    if (!proxy.allows(name)) return notFound();

    final known = await proxy.knownSha256(name, version);
    if (clientHasArchive(req, known)) {
      return shelf.Response.notModified(headers: app.archiveHeaders(known));
    }

    final UpstreamArchive? archive;
    try {
      archive = await proxy.archive(name, version);
    } on UpstreamBusyException catch (error) {
      return badRequest(error.message, status: HttpStatus.serviceUnavailable);
    } on UpstreamException catch (error) {
      return badGateway(error);
    }
    if (archive == null) return notFound();
    final headers = {
      ...app.archiveHeaders(null),
      HttpHeaders.etagHeader: archive.etag,
    };
    if (etagMatches(req.headers[HttpHeaders.ifNoneMatchHeader], archive.etag)) {
      return shelf.Response.notModified(headers: headers);
    }
    return shelf.Response.ok(
      archive.content,
      headers: {
        HttpHeaders.contentTypeHeader: ContentType.binary.mimeType,
        ...headers,
      },
    );
  }
}
