part of 'web_ui.dart';

/// The administration pages of phase 5: the audit log, package deletion and
/// ownership, and webhooks. They share the helpers of [WebUi].
class _AdminOpsUi {
  final WebUi web;

  _AdminOpsUi(this.web);

  App get app => web.app;

  PackageModeration get _moderation => web._moderation;

  void addRoutes(Router router) {
    router
      ..get('/admin/audit', web._guard(audit))
      ..get('/admin/packages/<name>/versions/<version>/delete',
          web._guard2(confirmDeleteVersion))
      ..post('/admin/packages/<name>/versions/<version>/delete',
          web._guard2(deleteVersion))
      ..post('/admin/packages/<name>/delete', web._guard1(deletePackage))
      ..post('/admin/packages/<name>/owner', web._guard1(transferOwnership));
  }

  Future<shelf.Response> audit(shelf.Request req) async {
    web._administrator(req);
    AuditQuery query;
    String? error;
    try {
      query = AuditQuery.fromParameters(req.url.queryParameters);
    } on FormatException catch (problem) {
      query = const AuditQuery();
      error = WebUi._sentence(problem.message);
    }
    final page = await app.auditStore.query(query);
    return WebUi._html(
        req, auditPage(web._context(req), query, page, error: error),
        status: error == null ? HttpStatus.ok : HttpStatus.badRequest);
  }

  Future<shelf.Response> confirmDeleteVersion(
      shelf.Request req, String name, String version) async {
    web._administrator(req);
    final decoded = parseVersionSegment(version);
    final package = isValidPackageName(name) && decoded != null
        ? await app.metaStore.queryPackage(name)
        : null;
    final target =
        package?.versions.firstWhereOrNull((item) => item.version == decoded);
    if (package == null || target == null) return web._notFoundPage(req);
    return WebUi._html(
        req, adminDeleteVersionPage(web._context(req), package, target));
  }

  Future<shelf.Response> deleteVersion(
      shelf.Request req, String name, String version) async {
    web._administrator(req);
    final decoded = parseVersionSegment(version);
    if (decoded == null) return web._notFoundPage(req);
    return web._changingPackage(req, name, (principal, form) async {
      await _moderation.deleteVersion(req, principal, name, decoded);
      return 'version-deleted';
    });
  }

  Future<shelf.Response> transferOwnership(shelf.Request req, String name) =>
      web._changingPackage(req, name, (principal, form) async {
        final email = normalizeEmail(WebUi._field(form, 'email') ?? '');
        if (!isValidEmail(email)) {
          throw const ModerationException.invalid('email is invalid');
        }
        await _moderation.transferOwnership(req, principal, name, email);
        return 'owner-transferred';
      });

  Future<shelf.Response> deletePackage(shelf.Request req, String name) async {
    final principal = web._administrator(req);
    if (!isValidPackageName(name)) return web._notFoundPage(req);
    final form = await WebUi._form(req);
    try {
      if (WebUi._field(form, 'confirm_name') != name) {
        throw ModerationException.invalid(
            'type the name $name to confirm the deletion');
      }
      await _moderation.deletePackage(req, principal, name);
      return WebUi._redirect('/admin/packages?done=package-deleted');
    } on ModerationException catch (error) {
      if (await app.metaStore.queryPackage(name) == null) {
        return web._notFoundPage(
            req, 'There is no package $name on this server.');
      }
      return web._adminPackagePage(req, name,
          error: WebUi._sentence(error.message), status: error.statusCode);
    }
  }
}
