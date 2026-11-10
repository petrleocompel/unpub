import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart';

import '../app.dart';
import '../auth/auth_middleware.dart';
import '../auth/authenticator.dart';
import '../auth/accounts.dart';
import '../store/audit_store.dart';
import 'responses.dart';

/// The JSON endpoints of the administration: the audit log.
class AdminApiRoutes {
  final App app;

  AdminApiRoutes(this.app);

  void addRoutes(Router router) {
    router.get('/webapi/audit', getAudit);
  }

  /// The administrator behind [req], or the response refusing it. Reading
  /// needs the read scope.
  static (Principal?, shelf.Response?) administrator(shelf.Request req,
      {bool reading = false}) {
    final principal = principalOf(req);
    if (principal == null) return (null, unauthenticated());
    if (!principal.isAdmin) {
      return (null, forbidden('administrator role required'));
    }
    if (reading && !principal.scopes.contains(Scope.read)) {
      return (null, forbidden('this token cannot read'));
    }
    return (principal, null);
  }

  Future<shelf.Response> getAudit(shelf.Request req) async {
    final (_, refused) = administrator(req, reading: true);
    if (refused != null) return refused;
    final AuditQuery query;
    try {
      query = AuditQuery.fromParameters(req.url.queryParameters);
    } on FormatException catch (error) {
      return badRequest(error.message);
    }
    final page = await app.auditStore.query(query);
    return okWithJson({
      'events': [for (final event in page.events) event.toJson()],
      'count': page.count,
      'page': query.page,
      'size': query.limit,
    }, headers: const {
      'cache-control': 'no-store'
    });
  }
}
