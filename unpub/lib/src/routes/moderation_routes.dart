import 'dart:io';

import 'package:collection/collection.dart' show IterableExtension;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart';

import '../app.dart';
import '../auth/auth_middleware.dart';
import '../validation.dart';
import 'responses.dart';
import 'route_support.dart';

/// Retracting versions and discontinuing packages.
class ModerationRoutes {
  final App app;

  ModerationRoutes(this.app);

  void addRoutes(Router router) {
    router
      ..post('/api/packages/<name>/versions/<version>/retract', retractVersion)
      ..post(
          '/api/packages/<name>/versions/<version>/unretract', unretractVersion)
      ..put('/api/packages/<name>/discontinue', discontinue);
  }

  Future<shelf.Response> retractVersion(
          shelf.Request req, String name, String version) =>
      _changeRetraction(req, name, version, retracted: true);

  Future<shelf.Response> unretractVersion(
          shelf.Request req, String name, String version) =>
      _changeRetraction(req, name, version, retracted: false);

  Future<shelf.Response> _changeRetraction(
      shelf.Request req, String name, String version,
      {required bool retracted}) async {
    final decodedVersion = parseVersionSegment(version);
    if (!isValidPackageName(name) || decodedVersion == null) return notFound();
    version = decodedVersion;

    final principal = principalOf(req);
    if (principal == null) return unauthenticated();

    final (package, refusal) = await app.packageForChange(name, principal);
    if (refusal != null) return refusal;

    final target =
        package!.versions.firstWhereOrNull((item) => item.version == version);
    if (target == null) return notFound('version not found');

    final now = DateTime.now();
    if (retracted &&
        !principal.isAdmin &&
        app.publishPolicy.retractionWindowClosed(target.createdAt, now)) {
      return badRequest(
          'publish.retractionWindow: $name@$version can no longer be '
          'retracted. Only an administrator can retract it now.',
          status: HttpStatus.forbidden);
    }

    final changed = await app.metaStore.setVersionRetracted(name, version,
        retracted: retracted,
        retractedAt: retracted ? now : null,
        retractedBy: retracted ? principal.email : null);
    if (changed) {
      await app.audit(
        req,
        principal,
        retracted ? 'version.retracted' : 'version.unretracted',
        '$name@$version',
      );
    }
    return successMessage(retracted ? 'version retracted' : 'version restored');
  }

  Future<shelf.Response> discontinue(shelf.Request req, String name) async {
    if (!isValidPackageName(name)) return notFound();

    final principal = principalOf(req);
    if (principal == null) return unauthenticated();

    final Object? body = await readJsonBody(req);
    if (body is! Map || body['isDiscontinued'] is! bool) {
      return badRequest('isDiscontinued must be true or false');
    }
    final discontinued = body['isDiscontinued'] as bool;
    final replacedBy = body['replacedBy'];
    if (replacedBy != null) {
      if (replacedBy is! String || !isValidPackageName(replacedBy)) {
        return badRequest('replacedBy must be a valid package name');
      }
      if (replacedBy == name) {
        return badRequest('a package cannot replace itself');
      }
      if (!discontinued) {
        return badRequest('replacedBy needs isDiscontinued to be true');
      }
    }

    final (package, refusal) = await app.packageForChange(name, principal);
    if (refusal != null) return refusal;

    final wasDiscontinued = package!.isDiscontinued;
    await app.metaStore.setDiscontinued(
      name,
      discontinued: discontinued,
      replacedBy: replacedBy as String?,
      discontinuedAt: discontinued
          ? (wasDiscontinued ? package.discontinuedAt : null) ?? DateTime.now()
          : null,
    );
    await app.audit(
      req,
      principal,
      discontinued ? 'package.discontinued' : 'package.continued',
      name,
      {if (replacedBy != null) 'replacedBy': replacedBy},
    );
    return successMessage(
        discontinued ? 'package discontinued' : 'package continued');
  }
}
