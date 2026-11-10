import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:shelf/shelf.dart' as shelf;

import '../app.dart';
import '../auth/authenticator.dart';
import '../config/config.dart';
import '../http_cache.dart';
import '../models.dart';
import '../pub_listing.dart';
import '../store/audit_store.dart';
import '../upstream/upstream_proxy.dart';
import 'responses.dart';

/// Changes when the listing format does, so that a client's validator from an
/// older server does not match.
const _listingFormat = 'listing-v2';

/// Helpers the route modules share. Not exported by `package:unpub`.
extension RouteSupport on App {
  String resolveUrl(shelf.Request req, String reference) {
    return (publicUrl ?? req.requestedUri).resolve(reference).toString();
  }

  bool get isPublicRead => readAccess == ReadAccess.public;

  Map<String, dynamic> versionToJson(UnpubVersion item, shelf.Request req) {
    final name = item.pubspec['name'] as String;
    return pubVersionJson(
      archiveUrl:
          resolveUrl(req, UpstreamProxy.archivePath(name, item.version)),
      archiveSha256: item.sha256,
      pubspec: item.pubspec,
      version: item.version,
      published: item.createdAt.toUtc().toIso8601String(),
      retracted: item.isRetracted,
    );
  }

  /// A validator for a JSON response built from [parts], which also varies
  /// with the origin in its URLs.
  String listingEtag(shelf.Request req, Iterable<Object?> parts) {
    final input = [_listingFormat, resolveUrl(req, '/'), ...parts].join('|');
    final digest = sha256.convert(utf8.encode(input)).toString();
    return 'W/"${digest.substring(0, 32)}"';
  }

  /// The validator of the listing of [package].
  ///
  /// Retracting or discontinuing does not touch `updatedAt`, which orders the
  /// package list, so the flags are part of the input.
  String packageEtag(shelf.Request req, UnpubPackage package) =>
      listingEtag(req, [
        package.updatedAt.millisecondsSinceEpoch,
        package.isDiscontinued,
        package.replacedBy,
        for (final item in package.versions)
          '${item.version}:${item.isRetracted}:${item.sha256}',
      ]);

  /// [body] as a JSON listing, or a 304 if the client already has [etag].
  shelf.Response listingResponse(
      shelf.Request req, String etag, Map<String, dynamic> Function() body) {
    final headers = {
      HttpHeaders.etagHeader: etag,
      HttpHeaders.cacheControlHeader:
          isPublicRead ? 'public, max-age=60' : 'private, no-store',
    };
    if (etagMatches(req.headers[HttpHeaders.ifNoneMatchHeader], etag)) {
      return shelf.Response.notModified(headers: headers);
    }
    return okWithJson(body(), headers: headers);
  }

  /// An archive can be cached for good only if nothing can replace it, which
  /// `publish.requireVersionBump: false` allows.
  String get archiveCacheControl {
    if (!isPublicRead) return 'private, no-store';
    return publishPolicy.config.requireVersionBump
        ? 'public, max-age=31536000, immutable'
        : 'public, max-age=60';
  }

  /// The headers of an archive whose hash is [hash], if known.
  Map<String, String> archiveHeaders(String? hash) => {
        HttpHeaders.cacheControlHeader: archiveCacheControl,
        if (hash != null) HttpHeaders.etagHeader: '"$hash"',
      };

  /// [version], a listing entry whose `archive_url` is a path on this server,
  /// with that made absolute.
  Map<String, dynamic> absoluteArchiveUrl(
          shelf.Request req, Map<String, dynamic> version) =>
      {
        ...version,
        'archive_url': resolveUrl(req, version['archive_url'] as String),
      };

  Future<void> audit(
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

  /// The package when [principal] may manage it, or the response refusing it.
  ///
  /// Only an administrator learns that a package does not exist.
  Future<(UnpubPackage?, shelf.Response?)> packageForChange(
      String name, Principal principal) async {
    final package = await metaStore.queryPackage(name);
    if (package == null && principal.canPublish && principal.isAdmin) {
      return (null, notFound());
    }
    if (package == null || !principal.canChangePackage(package.uploaders)) {
      return (null, badRequest('no permission', status: HttpStatus.forbidden));
    }
    return (package, null);
  }
}

bool clientHasArchive(shelf.Request req, String? hash) =>
    hash != null &&
    etagMatches(req.headers[HttpHeaders.ifNoneMatchHeader], '"$hash"');
