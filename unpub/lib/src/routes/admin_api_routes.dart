import 'dart:io';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart';

import '../app.dart';
import '../auth/auth_middleware.dart';
import '../auth/authenticator.dart';
import '../auth/accounts.dart';
import '../config/config.dart';
import '../store/audit_store.dart';
import '../web/settings.dart';
import '../webhooks/webhook_service.dart';
import 'health_routes.dart';
import 'responses.dart';
import 'route_support.dart';

final _log = Logger('unpub.admin');

/// The JSON endpoints of the administration: the dashboard, the settings,
/// the audit log and webhooks.
class AdminApiRoutes {
  final App app;

  AdminApiRoutes(this.app);

  void addRoutes(Router router) {
    router
      ..get('/webapi/settings', getSettings)
      ..get('/webapi/admin/overview', getOverview)
      ..get('/webapi/audit', getAudit)
      ..get('/webapi/webhooks', _hooks(listWebhooks))
      ..post('/webapi/webhooks', _hooks(createWebhook))
      ..get('/webapi/webhooks/<id>', _hooks1(getWebhook))
      ..patch('/webapi/webhooks/<id>', _hooks1(updateWebhook))
      ..delete('/webapi/webhooks/<id>', _hooks1(deleteWebhook))
      ..post('/webapi/webhooks/<id>/secret', _hooks1(rotateSecret))
      ..get('/webapi/webhooks/<id>/deliveries', _hooks1(listDeliveries))
      ..post('/webapi/webhooks/<id>/deliveries/<delivery>/redeliver',
          _hooks2(redeliver));
  }

  /// A webhook route for an administrator, reading needing the read scope.
  /// The middleware already requires the publish scope to write.
  Future<shelf.Response> _webhookRoute(shelf.Request req,
      Future<shelf.Response> Function(WebhookService, Principal) route) async {
    final reading = req.method == 'GET' || req.method == 'HEAD';
    final (principal, refused) = administrator(req, reading: reading);
    if (refused != null) return refused;
    final webhooks = app.webhooks;
    if (webhooks == null) return notFound('this server has no webhooks');
    try {
      return await route(webhooks, principal!);
    } on WebhookException catch (error) {
      return badRequest(error.message, status: error.statusCode);
    }
  }

  shelf.Handler _hooks(
          Future<shelf.Response> Function(
                  shelf.Request, WebhookService, Principal)
              route) =>
      (req) => _webhookRoute(req, (hooks, who) => route(req, hooks, who));

  Function _hooks1(
          Future<shelf.Response> Function(
                  shelf.Request, WebhookService, Principal, String)
              route) =>
      (shelf.Request req, String id) =>
          _webhookRoute(req, (hooks, who) => route(req, hooks, who, id));

  Function _hooks2(
          Future<shelf.Response> Function(
                  shelf.Request, WebhookService, Principal, String, String)
              route) =>
      (shelf.Request req, String id, String other) =>
          _webhookRoute(req, (hooks, who) => route(req, hooks, who, id, other));

  static Future<Map<String, dynamic>> _body(shelf.Request req) async {
    final body = await readJsonBody(req);
    if (body is Map<String, dynamic>) return body;
    throw const WebhookException.invalid('the body must be a JSON object');
  }

  static const _noStore = {'cache-control': 'no-store'};

  Future<shelf.Response> listWebhooks(
      shelf.Request req, WebhookService hooks, Principal principal) async {
    final all = await hooks.store.list();
    final (:page, :size) = pageParameters(req.url.queryParameters);
    final shown = pageOf(all, page: page, size: size);
    final counts =
        await hooks.store.statusCountsOf([for (final hook in shown) hook.id]);
    return okWithJson({
      ...pageJson([
        for (final hook in shown)
          {...hook.toJson(), 'deliveries': counts[hook.id]},
      ], page: page, size: size, total: all.length),
      'enabled': hooks.config.enabled,
    }, headers: _noStore);
  }

  Future<shelf.Response> createWebhook(
      shelf.Request req, WebhookService hooks, Principal principal) async {
    final body = await _body(req);
    final (hook, secret) = await hooks.create(
        url: body['url'],
        events: body['events'],
        description: body['description'],
        by: app.auditContext(req, principal));
    return okWithJson({'webhook': hook.toJson(), 'secret': secret},
        headers: _noStore, status: HttpStatus.created);
  }

  Future<shelf.Response> getWebhook(shelf.Request req, WebhookService hooks,
      Principal principal, String id) async {
    final hook = await hooks.require(id);
    return okWithJson({
      'webhook': hook.toJson(),
      'deliveries': await hooks.store.statusCounts(id),
    }, headers: _noStore);
  }

  Future<shelf.Response> updateWebhook(shelf.Request req, WebhookService hooks,
      Principal principal, String id) async {
    final body = await _body(req);
    final hook = await hooks.update(id,
        url: body['url'],
        events: body['events'],
        description: body['description'],
        enabled: body['enabled'],
        by: app.auditContext(req, principal));
    return okWithJson({'webhook': hook.toJson()}, headers: _noStore);
  }

  Future<shelf.Response> deleteWebhook(shelf.Request req, WebhookService hooks,
      Principal principal, String id) async {
    await hooks.delete(id, by: app.auditContext(req, principal));
    return successMessage('webhook deleted');
  }

  Future<shelf.Response> rotateSecret(shelf.Request req, WebhookService hooks,
      Principal principal, String id) async {
    final secret =
        await hooks.rotateSecret(id, by: app.auditContext(req, principal));
    return okWithJson({'secret': secret}, headers: _noStore);
  }

  Future<shelf.Response> listDeliveries(shelf.Request req, WebhookService hooks,
      Principal principal, String id) async {
    await hooks.require(id);
    final (:page, :size) = pageParameters(req.url.queryParameters);
    final deliveries = await hooks.store
        .deliveries(id, skip: pageOffset(page, size), limit: size);
    return okWithJson(
        pageJson([for (final delivery in deliveries) delivery.toJson()],
            page: page,
            size: size,
            total: await hooks.store.countDeliveries(id)),
        headers: _noStore);
  }

  Future<shelf.Response> redeliver(shelf.Request req, WebhookService hooks,
      Principal principal, String id, String delivery) async {
    await hooks.redeliver(id, delivery, by: app.auditContext(req, principal));
    return successMessage('delivery queued');
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
    return okWithJson(
        pageJson([for (final event in page.events) event.toJson()],
            page: query.page, size: query.limit, total: page.count),
        headers: _noStore);
  }

  /// The effective configuration by section, as the settings page shows it,
  /// with the environment variable of each key and where its value came from.
  Future<shelf.Response> getSettings(shelf.Request req) async {
    final (_, refused) = administrator(req, reading: true);
    if (refused != null) return refused;
    final config = app.config;
    return okWithJson({
      'configured': config != null,
      'sections': [
        if (config != null)
          for (final MapEntry(key: section, value: values)
              in settingsOverview(config).entries)
            {
              'name': section,
              'settings': [
                for (final MapEntry(:key, :value) in values.entries)
                  {
                    'key': '$section.$key',
                    'value': value,
                    'env': environmentVariableFor('$section.$key'),
                    'source': config.sourceOf('$section.$key').label,
                  },
              ],
            },
      ],
    }, headers: _noStore);
  }

  /// What the dashboard shows: counts, recent publishes, failed deliveries
  /// and the readiness checks.
  Future<shelf.Response> getOverview(shelf.Request req) async {
    final (_, refused) = administrator(req, reading: true);
    if (refused != null) return refused;
    final since = DateTime.now().toUtc().subtract(const Duration(days: 1));
    final hooks = app.webhooks;
    final storage = app.metricsSources.storage.current;
    final counts = await _optional(app.metaStore.counts);
    final recent = await app.auditStore
        .query(const AuditQuery(action: 'package.published', size: 10));
    final lastDay = await app.auditStore
        .query(AuditQuery(action: 'package.published', from: since, size: 1));
    return okWithJson({
      'packages': counts?.packages,
      'versions': counts?.versions,
      'users': await _optional(
          () async => await app.accountApi?.accounts.store.countUsers()),
      'webhooks': hooks == null
          ? null
          : await _optional(() async => (await hooks.store.list()).length),
      'storageBytes': storage?.value,
      'storageMeasuredAt':
          storage?.value == null ? null : storage!.at.toUtc().toIso8601String(),
      'publishesLast24h': lastDay.count,
      'failedDeliveriesLast24h': hooks == null
          ? 0
          : await _optional(() => hooks.store.countFailedSince(since)) ?? 0,
      'recentPublishes': [for (final event in recent.events) event.toJson()],
      'readiness': await HealthRoutes(app).readiness(),
    }, headers: _noStore);
  }

  /// The value of [read], or null if it fails, so that one broken source
  /// does not take the dashboard down.
  static Future<T?> _optional<T>(Future<T?> Function() read) async {
    try {
      return await read();
    } catch (error) {
      _log.warning('a source of the admin overview failed: $error');
      return null;
    }
  }
}
