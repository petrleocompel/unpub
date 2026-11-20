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
      ..get(web._at('/admin/audit'), web._guard(audit))
      ..get(web._at('/admin/packages/<name>/versions/<version>/delete'),
          web._guard2(confirmDeleteVersion))
      ..post(web._at('/admin/packages/<name>/versions/<version>/delete'),
          web._guard2(deleteVersion))
      ..post(
          web._at('/admin/packages/<name>/delete'), web._guard1(deletePackage))
      ..get(web._at('/admin/packages/<name>/owner'),
          web._guard1(confirmTransferOwnership))
      ..post(web._at('/admin/packages/<name>/owner'),
          web._guard1(transferOwnership))
      ..get(web._at('/admin/webhooks'), web._guard(webhooks))
      ..post(web._at('/admin/webhooks'), web._guard(createWebhook))
      ..get(web._at('/admin/webhooks/<id>'), web._guard1(webhook))
      ..post(web._at('/admin/webhooks/<id>/enabled'),
          web._guard1(setWebhookEnabled))
      ..post(web._at('/admin/webhooks/<id>/secret'),
          web._guard1(rotateWebhookSecret))
      ..get(web._at('/admin/webhooks/<id>/delete'),
          web._guard1(confirmDeleteWebhook))
      ..post(web._at('/admin/webhooks/<id>/delete'), web._guard1(deleteWebhook))
      ..post(web._at('/admin/webhooks/<id>/deliveries/<delivery>/redeliver'),
          web._guard2(redeliver));
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

  /// Asks before [transferOwnership], which the form of the package page
  /// leads to, so that the transfer needs a second step without JavaScript.
  Future<shelf.Response> confirmTransferOwnership(
      shelf.Request req, String name) async {
    web._administrator(req);
    final package = isValidPackageName(name)
        ? await app.metaStore.queryPackage(name)
        : null;
    if (package == null) return web._notFoundPage(req);
    final email = normalizeEmail(req.url.queryParameters['email'] ?? '');
    if (!isValidEmail(email)) {
      return web._adminPackagePage(req, name,
          error: 'The email is invalid.', status: HttpStatus.badRequest);
    }
    return WebUi._html(
        req, adminTransferOwnershipPage(web._context(req), package, email));
  }

  Future<shelf.Response> transferOwnership(shelf.Request req, String name) =>
      web._changingPackage(req, name, (principal, form) async {
        if (!_confirmed(form)) {
          throw const ModerationException.invalid(
              'confirm the transfer on its confirmation page');
        }
        final email = normalizeEmail(WebUi._field(form, 'email') ?? '');
        if (!isValidEmail(email)) {
          throw const ModerationException.invalid('email is invalid');
        }
        await _moderation.transferOwnership(req, principal, name, email);
        return 'owner-transferred';
      });

  /// Whether [form] carries the `confirm` field of a confirmation page or
  /// checkbox, which irreversible changes need.
  static bool _confirmed(Map<String, List<String>> form) =>
      WebUi._field(form, 'confirm') == 'yes';

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

  // Webhooks.

  WebhookService _webhooks() {
    final hooks = app.webhooks;
    if (hooks == null) {
      throw const AccountException.notFound('This server has no webhooks.');
    }
    return hooks;
  }

  Future<shelf.Response> _webhooksPage(shelf.Request req, WebhookService hooks,
          {String? notice,
          String? error,
          Map<String, Object> form = const {},
          int status = HttpStatus.ok}) async =>
      WebUi._html(
          req,
          adminWebhooksPage(web._context(req), await hooks.store.list(),
              deliveryEnabled: hooks.config.enabled,
              allowHttp: hooks.config.allowHttp,
              notice: notice,
              error: error,
              form: form),
          status: status);

  Future<shelf.Response> webhooks(shelf.Request req) async {
    web._administrator(req);
    return _webhooksPage(req, _webhooks(),
        notice: _doneMessages[req.url.queryParameters['done']]);
  }

  Future<shelf.Response> createWebhook(shelf.Request req) async {
    final principal = web._administrator(req);
    final hooks = _webhooks();
    final form = await WebUi._form(req);
    final events = form['events'] ?? const <String>[];
    try {
      final (hook, secret) = await hooks.create(
          url: WebUi._field(form, 'url'),
          events: events,
          description: WebUi._field(form, 'description'),
          by: app.auditContext(req, principal));
      return _showSecret(req, hook.id, secret, 'created');
    } on WebhookException catch (error) {
      return _webhooksPage(req, hooks,
          error: WebUi._sentence(error.message),
          status: error.statusCode,
          form: {
            if (WebUi._field(form, 'url') case final url?) 'url': url,
            'events': events,
            if (WebUi._field(form, 'description') case final text?)
              'description': text,
          });
    }
  }

  Future<shelf.Response> _webhookPage(
      shelf.Request req, WebhookService hooks, String id,
      {String? secret,
      String? notice,
      String? error,
      int status = HttpStatus.ok}) async {
    final hook = await hooks.store.find(id);
    if (hook == null) {
      return web._notFoundPage(req, 'There is no such webhook.');
    }
    return WebUi._html(
        req,
        adminWebhookPage(
            web._context(req), hook, await hooks.store.deliveries(id),
            secret: secret, notice: notice, error: error),
        status: status);
  }

  /// Redirects to the page of the webhook [id], which shows [secret] once,
  /// so that reloading it does not repeat the post.
  shelf.Response _showSecret(
      shelf.Request req, String id, String secret, String done) {
    if (WebUi._sessionId(req) case final session?) {
      web._flash.put(session, 'webhook:$id', secret);
    }
    return WebUi._redirect('${webhookHref(id)}?done=$done');
  }

  Future<shelf.Response> webhook(shelf.Request req, String id) async {
    web._administrator(req);
    final done = req.url.queryParameters['done'];
    final changed = switch (done) {
      'created' => 'The webhook was added.',
      'secret-rotated' => 'The secret was replaced.',
      _ => null,
    };
    if (changed == null) {
      return _webhookPage(req, _webhooks(), id, notice: _doneMessages[done]);
    }
    final session = WebUi._sessionId(req);
    final secret = session == null
        ? null
        : web._flash.take<String>(session, 'webhook:$id');
    return _webhookPage(req, _webhooks(), id,
        secret: secret,
        notice: secret != null
            ? changed
            : '$changed The secret is shown only once: rotate it again if it '
                'was not copied.');
  }

  /// Runs [change] of the webhook [id] and goes back to its page.
  Future<shelf.Response> _changingWebhook(
      shelf.Request req,
      String id,
      Future<String> Function(
              WebhookService, AuditContext, Map<String, List<String>>)
          change) async {
    final principal = web._administrator(req);
    final hooks = _webhooks();
    final form = await WebUi._form(req);
    try {
      final done = await change(hooks, app.auditContext(req, principal), form);
      return WebUi._redirect('${webhookHref(id)}?done=$done');
    } on WebhookException catch (error) {
      if (error.statusCode == HttpStatus.notFound &&
          await hooks.store.find(id) == null) {
        return web._notFoundPage(req, 'There is no such webhook.');
      }
      return _webhookPage(req, hooks, id,
          error: WebUi._sentence(error.message), status: error.statusCode);
    }
  }

  Future<shelf.Response> setWebhookEnabled(shelf.Request req, String id) =>
      _changingWebhook(req, id, (hooks, by, form) async {
        final enabled = switch (WebUi._field(form, 'enabled')) {
          'true' => true,
          'false' => false,
          _ => throw const WebhookException.invalid(
              'enabled must be true or false'),
        };
        await hooks.update(id, enabled: enabled, by: by);
        return 'webhook-updated';
      });

  Future<shelf.Response> rotateWebhookSecret(
      shelf.Request req, String id) async {
    final principal = web._administrator(req);
    final hooks = _webhooks();
    final form = await WebUi._form(req);
    try {
      if (!_confirmed(form)) {
        await hooks.require(id);
        return await _webhookPage(req, hooks, id,
            error: 'Tick the box to confirm that the receiver will need the '
                'new secret.',
            status: HttpStatus.badRequest);
      }
      final secret =
          await hooks.rotateSecret(id, by: app.auditContext(req, principal));
      return _showSecret(req, id, secret, 'secret-rotated');
    } on WebhookException {
      return web._notFoundPage(req, 'There is no such webhook.');
    }
  }

  /// Asks before [deleteWebhook].
  Future<shelf.Response> confirmDeleteWebhook(
      shelf.Request req, String id) async {
    web._administrator(req);
    final hook = await _webhooks().store.find(id);
    if (hook == null) {
      return web._notFoundPage(req, 'There is no such webhook.');
    }
    return WebUi._html(req, adminDeleteWebhookPage(web._context(req), hook));
  }

  Future<shelf.Response> deleteWebhook(shelf.Request req, String id) async {
    final principal = web._administrator(req);
    final hooks = _webhooks();
    final form = await WebUi._form(req);
    try {
      if (!_confirmed(form)) {
        await hooks.require(id);
        return await _webhookPage(req, hooks, id,
            error: 'Confirm the deletion on its confirmation page.',
            status: HttpStatus.badRequest);
      }
      await hooks.delete(id, by: app.auditContext(req, principal));
    } on WebhookException {
      return web._notFoundPage(req, 'There is no such webhook.');
    }
    return WebUi._redirect('/admin/webhooks?done=webhook-deleted');
  }

  Future<shelf.Response> redeliver(
          shelf.Request req, String id, String delivery) =>
      _changingWebhook(req, id, (hooks, by, form) async {
        await hooks.redeliver(id, delivery, by: by);
        return 'redelivery-queued';
      });
}
