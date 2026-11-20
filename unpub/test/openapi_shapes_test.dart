import 'dart:io';

import 'package:test/test.dart';
import 'package:unpub/unpub.dart';

import 'harness.dart';
import 'openapi_schema.dart';

/// The JSON of the main routes against the schemas of docs/openapi.yaml.
void main() {
  final harness = Harness(
      builder: (h) => h.buildApp(
          webhooks: WebhookService(WebhookStore(h.db),
              config: const WebhooksConfig(
                  allowHttp: true, allowPrivateNetworks: true),
              audit: h.audit)));
  harness.install();

  test('the checker catches a missing field and a wrong type', () {
    final delivery = {
      'id': 'a',
      'webhookId': 'b',
      'event': 'package.published',
      'eventId': 'c',
      'package': null,
      'version': null,
      'status': 'pending',
      'attempt': 0,
      'nextAt': null,
      'createdAt': '2026-11-10T00:00:00.000Z',
      'lastAttemptAt': null,
      'finishedAt': null,
      'durationMs': null,
      'response': null,
      'error': null,
      'redeliveryOf': null,
    };
    expect(schemaProblems(delivery, 'Delivery'), [contains('lacks `payload`')]);
    expect(schemaProblems({...delivery, 'payload': '{}'}, 'Delivery'), isEmpty);
    expect(
        schemaProblems(
            {...delivery, 'payload': '{}', 'attempt': '0'}, 'Delivery'),
        [contains('Delivery.attempt')]);
    expect(
        schemaProblems(
            {...delivery, 'payload': '{}', 'response': 1}, 'Delivery'),
        [contains('oneOf')]);
  });

  test('an anonymous visitor is told that nobody is logged in', () async {
    final reply = await harness.send('GET', '/webapi/me');
    expect(reply.status, HttpStatus.ok, reason: reply.body);
    expectSchema(reply.json, 'Anonymous');
    expect(schemaProblems(reply.json, 'Me'), isNotEmpty);
  });

  test('every main object has the documented shape', () async {
    final admin = await harness.user('admin@example.com', Role.admin);
    final login = await harness.send('POST', '/webapi/login',
        json: {'email': 'admin@example.com', 'password': harnessPassword});
    expect(login.status, HttpStatus.ok, reason: login.body);
    expectSchema(login.json, 'LoginResult');
    final browser = await harness.apiLogIn('admin@example.com');
    Future<Object?> get(String path) async {
      final reply = await harness.send('GET', path, as: browser);
      expect(reply.status, HttpStatus.ok, reason: '$path: ${reply.body}');
      return reply.json;
    }

    await harness.publish('alpha', '1.0.0', bearer: await harness.token(admin));
    await harness.publish('alpha', '1.1.0', bearer: await harness.token(admin));

    final token = await harness.send('POST', '/webapi/tokens',
        as: browser, json: {'name': 'ci', 'expiresIn': '90d'});
    expect(token.status, HttpStatus.created, reason: token.body);
    expectSchema(token.json, 'TokenCreated');

    final hook =
        await harness.send('POST', '/webapi/webhooks', as: browser, json: {
      'url': 'http://127.0.0.1:9/hook',
      'events': ['package.published'],
    });
    expect(hook.status, HttpStatus.created, reason: hook.body);
    expectSchema(hook.json, 'WebhookCreated');
    final id = hook.json['webhook']['id'] as String;
    final stored = (await WebhookStore(harness.db).find(id))!;
    await WebhookStore(harness.db).enqueue([stored],
        event: 'package.published', eventId: 'e1', payload: '{"id":"e1"}');

    for (final (path, schema) in [
      ('/webapi/config', 'Config'),
      ('/webapi/me', 'Me'),
      ('/webapi/v2/packages', 'PackagePage'),
      ('/webapi/package/alpha', 'PackageResponse'),
      ('/webapi/package/alpha/1.0.0', 'PackageResponse'),
      ('/webapi/package/alpha/stats', 'Stats'),
      ('/webapi/users', 'UserPage'),
      ('/webapi/tokens', 'TokenPage'),
      ('/webapi/audit', 'AuditPage'),
      ('/webapi/webhooks', 'WebhookPage'),
      ('/webapi/webhooks/$id/deliveries', 'DeliveryPage'),
      ('/webapi/settings', 'Settings'),
      ('/webapi/admin/overview', 'Overview'),
    ]) {
      final json = await get(path);
      expectSchema(json, schema);
      if (json case {'items': final List items}) {
        expect(items, isNotEmpty, reason: '$path checks no item');
      }
    }
  });
}
