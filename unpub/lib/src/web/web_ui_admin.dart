part of 'web_ui.dart';

/// The administration pages of phase 5: the audit log, package deletion and
/// ownership, and webhooks. They share the helpers of [WebUi].
class _AdminOpsUi {
  final WebUi web;

  _AdminOpsUi(this.web);

  App get app => web.app;

  void addRoutes(Router router) {
    router.get('/admin/audit', web._guard(audit));
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
}
