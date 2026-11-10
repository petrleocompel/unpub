import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart';

import '../app.dart';
import '../auth/auth_middleware.dart';
import '../package_moderation.dart';
import '../validation.dart';
import 'responses.dart';

/// Retracting versions and discontinuing packages.
class ModerationRoutes {
  final App app;

  final PackageModeration _moderation;

  ModerationRoutes(this.app) : _moderation = PackageModeration(app);

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

    return moderationResponse(() => _moderation
        .setRetracted(req, principal, name, version, retracted: retracted));
  }

  Future<shelf.Response> discontinue(shelf.Request req, String name) async {
    if (!isValidPackageName(name)) return notFound();

    final principal = principalOf(req);
    if (principal == null) return unauthenticated();

    final Object? body = await readJsonBody(req);
    if (body is! Map || body['isDiscontinued'] is! bool) {
      return badRequest('isDiscontinued must be true or false');
    }
    return moderationResponse(() => _moderation.setDiscontinued(
        req, principal, name,
        discontinued: body['isDiscontinued'] as bool,
        replacedBy: body['replacedBy']));
  }
}
