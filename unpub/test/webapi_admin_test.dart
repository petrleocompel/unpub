import 'dart:io';

import 'package:test/test.dart';
import 'package:unpub/src/paging.dart' show maxPage;
import 'package:unpub/unpub.dart';

import 'harness.dart';
import 'openapi_schema.dart';

const _bootstrap = 'bootstrap-secret-token';

/// The administration routes of the web client, the list shapes, and the
/// CSRF rule on every change the client makes.
void main() {
  late WebhookService hooks;

  final harness = Harness(builder: (h) {
    hooks = WebhookService(WebhookStore(h.db),
        config:
            const WebhooksConfig(allowHttp: true, allowPrivateNetworks: true),
        audit: h.audit);
    return h.buildApp(webhooks: hooks, bootstrapToken: _bootstrap);
  });
  harness.install();

  Future<Reply> send(String method, String path,
          {String? bearer,
          Browser? as,
          Object? json,
          bool csrf = true,
          App? using}) =>
      harness.send(method, path,
          bearer: bearer, as: as, json: json, csrf: csrf, using: using);

  /// Who the matrix tries, by label, and whether an administrator's read
  /// should work for them.
  Future<Map<String, (Future<Reply> Function(String), bool)>> people(
      {App? using}) async {
    final reader = await harness.user('reader@example.com', Role.reader);
    await harness.user('pub@example.com', Role.publisher);
    final admin = await harness.user('admin@example.com', Role.admin);
    final readerSession =
        await harness.apiLogIn('reader@example.com', using: using);
    final publisherSession =
        await harness.apiLogIn('pub@example.com', using: using);
    final adminSession =
        await harness.apiLogIn('admin@example.com', using: using);
    final readToken = await harness.token(admin, scopes: {Scope.read});
    final publishToken = await harness.token(admin, scopes: {Scope.publish});
    final readerToken = await harness.token(reader);
    return {
      'anonymous': ((path) => send('GET', path, using: using), false),
      'reader session': (
        (path) => send('GET', path, as: readerSession, using: using),
        false
      ),
      'reader token': (
        (path) => send('GET', path, bearer: readerToken, using: using),
        false
      ),
      'publisher session': (
        (path) => send('GET', path, as: publisherSession, using: using),
        false
      ),
      'admin session': (
        (path) => send('GET', path, as: adminSession, using: using),
        true
      ),
      'admin read token': (
        (path) => send('GET', path, bearer: readToken, using: using),
        true
      ),
      'admin token without read': (
        (path) => send('GET', path, bearer: publishToken, using: using),
        false
      ),
      'bootstrap token': (
        (path) => send('GET', path, bearer: _bootstrap, using: using),
        true
      ),
    };
  }

  group('administrator reads', () {
    for (final path in ['/webapi/settings', '/webapi/admin/overview']) {
      test('$path is for administrators with the read scope', () async {
        for (final MapEntry(key: who, value: (read, allowed))
            in (await people()).entries) {
          final reply = await read(path);
          final expected = allowed
              ? HttpStatus.ok
              : who == 'anonymous'
                  ? HttpStatus.unauthorized
                  : HttpStatus.forbidden;
          expect(reply.status, expected, reason: '$who: ${reply.body}');
          expect(reply.headers['content-type'], contains('json'));
          if (!allowed) expect(reply.json['error']['code'], isA<String>());
        }
      });
    }

    test('readAccess authenticated changes nothing for them', () async {
      final private = harness.buildApp(
          webhooks: hooks,
          bootstrapToken: _bootstrap,
          readAccess: ReadAccess.authenticated);
      final all = await people(using: private);
      expect((await all['anonymous']!.$1('/webapi/settings')).status,
          HttpStatus.unauthorized);
      expect((await all['admin session']!.$1('/webapi/settings')).status,
          HttpStatus.ok);
    });
  });

  group('GET /webapi/settings', () {
    test('lists the redacted configuration with the variables', () async {
      final config = Config.parse('''
mongo:
  uri: mongodb://user:mongo-password@localhost:27017/dart_pub
storage:
  type: s3
  s3:
    bucket: packages
    region: eu-west-1
    accessKey: s3-access
    secretKey: s3-secret
auth:
  bootstrapToken: $_bootstrap
  readTokens: [reader-secret]
  admin:
    email: root@example.com
    password: admin-password
metrics:
  token: metrics-secret
''', environment: {});
      final app = harness.buildApp(config: config, bootstrapToken: _bootstrap);
      final reply =
          await send('GET', '/webapi/settings', bearer: _bootstrap, using: app);
      expect(reply.status, HttpStatus.ok, reason: reply.body);
      expect(reply.headers['cache-control'], 'no-store');
      expect(reply.json['configured'], isTrue);
      final sections = reply.json['sections'] as List;
      expect([
        for (final section in sections) section['name']
      ], [
        'server',
        'mongo',
        'storage',
        'upstream',
        'publish',
        'auth',
        'audit',
        'webhooks',
        'metrics',
        'ui',
        'logging',
      ]);
      final settings = {
        for (final section in sections)
          for (final setting in section['settings'] as List)
            setting['key'] as String: setting as Map,
      };
      expect(settings['server.publicUrl'], {
        'key': 'server.publicUrl',
        'value': '(not set)',
        'env': 'UNPUB_SERVER_PUBLIC_URL',
        'source': 'default'
      });
      expect(settings['storage.s3.bucket']!['source'], 'file');
      expect(settings['storage.s3.useSSL']!['env'], 'UNPUB_STORAGE_S3_USE_SSL');
      expect(settings['storage.s3.secretKey']!['value'], '<redacted>');
      expect(settings['auth.admin.password']!['value'], '<redacted>');
      expect(settings['metrics.token']!['value'], '<redacted>');
      expect(settings['ui.mode']!['value'], 'ssr');
      for (final secret in [
        'mongo-password',
        's3-access',
        's3-secret',
        _bootstrap,
        'reader-secret',
        'admin-password',
        'metrics-secret',
      ]) {
        expect(reply.body, isNot(contains(secret)), reason: secret);
      }
    });

    test('is empty when embedded without a configuration', () async {
      final reply = await send('GET', '/webapi/settings', bearer: _bootstrap);
      expect(reply.json, {'configured': false, 'sections': []});
    });
  });

  group('GET /webapi/admin/overview', () {
    test('counts what the registry holds', () async {
      final publisher = await harness.user('pub@example.com', Role.publisher);
      await harness.user('reader@example.com', Role.reader);
      final secret = await harness.token(publisher);
      await harness.publish('alpha', '1.0.0', bearer: secret);
      await harness.publish('alpha', '1.1.0', bearer: secret);
      await harness.publish('beta', '0.1.0', bearer: secret);
      final store = WebhookStore(harness.db);
      final hook = await store.insert(
          url: Uri.parse('http://127.0.0.1:9/hook'),
          events: ['package.published'],
          description: '',
          secret: 'hook-secret');
      final deliveries = harness.db.collection('webhook_deliveries');
      final now = DateTime.now().toUtc();
      for (final (status, finished) in [
        ('failed', now.subtract(const Duration(hours: 1))),
        ('failed', now.subtract(const Duration(days: 2))),
        ('succeeded', now),
      ]) {
        await deliveries.insertOne({
          'webhookId': hook.id,
          'event': 'package.published',
          'eventId': 'e',
          'payload': '{}',
          'status': status,
          'attempt': 1,
          'nextAt': finished,
          'createdAt': finished,
          'finishedAt': finished,
        });
      }

      final reply =
          await send('GET', '/webapi/admin/overview', bearer: _bootstrap);
      expect(reply.status, HttpStatus.ok, reason: reply.body);
      final body = reply.json as Map<String, dynamic>;
      expect(
          body.keys,
          unorderedEquals([
            'packages',
            'versions',
            'users',
            'webhooks',
            'storageBytes',
            'storageMeasuredAt',
            'publishesLast24h',
            'failedDeliveriesLast24h',
            'recentPublishes',
            'readiness',
          ]));
      expect(body['packages'], 2);
      expect(body['versions'], 3);
      expect(body['users'], 2);
      expect(body['webhooks'], 1);
      expect(body['publishesLast24h'], 3);
      expect(body['failedDeliveriesLast24h'], 1);
      expect([for (final event in body['recentPublishes']) event['version']],
          ['0.1.0', '1.1.0', '1.0.0']);
      expect(body['readiness']['status'], 'ok');
      expect(body['readiness']['checks'].keys,
          unorderedEquals(['mongo', 'storage']));
    });
  });

  group('list routes', () {
    test('users are searched and paged', () async {
      for (final name in ['carol', 'alice', 'bob']) {
        await harness.user('$name@example.com', Role.reader);
      }
      await harness.accounts.createUser(
          email: 'dave@example.com',
          role: Role.reader,
          displayName: 'Alice Two');
      Future<Map<String, dynamic>> users(String query) async {
        final reply =
            await send('GET', '/webapi/users$query', bearer: _bootstrap);
        expect(reply.status, HttpStatus.ok, reason: reply.body);
        return reply.json as Map<String, dynamic>;
      }

      List<String> emails(Map<String, dynamic> page) =>
          [for (final user in page['items']) user['email'] as String];

      final all = await users('');
      expect(all.keys, unorderedEquals(['items', 'page', 'size', 'total']));
      expect(emails(all), [
        'alice@example.com',
        'bob@example.com',
        'carol@example.com',
        'dave@example.com',
      ]);
      expect(all['total'], 4);
      final second = await users('?size=2&page=2');
      expect(emails(second), ['carol@example.com', 'dave@example.com']);
      expect(second['total'], 4);
      expect(second['page'], 2);
      expect(second['size'], 2);
      expect(emails(await users('?q=ALICE')),
          ['alice@example.com', 'dave@example.com']);
      expect((await users('?q=a.c'))['total'], 0);
      expect((await users('?size=500'))['size'], 100);
    });

    test('tokens, webhooks, deliveries and the audit log are pages', () async {
      final admin = await harness.user('admin@example.com', Role.admin);
      for (var i = 0; i < 3; i++) {
        await harness.token(admin);
      }
      final browser = await harness.apiLogIn('admin@example.com');
      final tokens = await send('GET', '/webapi/tokens?size=2', as: browser);
      expect(tokens.json.keys,
          unorderedEquals(['items', 'page', 'size', 'total']));
      expect(tokens.json['items'], hasLength(2));
      expect(tokens.json['total'], 3);

      final created =
          await send('POST', '/webapi/webhooks', as: browser, json: {
        'url': 'http://127.0.0.1:9/hook',
        'events': ['package.published'],
      });
      expect(created.status, HttpStatus.created, reason: created.body);
      final id = created.json['webhook']['id'] as String;
      final list = await send('GET', '/webapi/webhooks', as: browser);
      expect(list.json.keys,
          unorderedEquals(['items', 'page', 'size', 'total', 'enabled']));
      expect(list.json['total'], 1);

      final hook = (await WebhookStore(harness.db).find(id))!;
      for (var i = 0; i < 3; i++) {
        await WebhookStore(harness.db).enqueue([hook],
            event: 'package.published', eventId: 'e$i', payload: '{}');
      }
      final second = await send('POST', '/webapi/webhooks', as: browser, json: {
        'url': 'http://127.0.0.1:9/other',
        'events': ['package.deleted'],
      });
      final secondId = second.json['webhook']['id'] as String;
      await harness.db.collection('webhook_deliveries').updateOne({
        'eventId': 'e0'
      }, {
        r'$set': {'status': 'failed'}
      });
      final counted = await send('GET', '/webapi/webhooks', as: browser);
      final byId = {
        for (final item in counted.json['items'] as List)
          item['id']: item['deliveries'],
      };
      expect(byId[id], {'pending': 2, 'succeeded': 0, 'failed': 1});
      expect(byId[secondId], {'pending': 0, 'succeeded': 0, 'failed': 0});

      final page = await send(
          'GET', '/webapi/webhooks/$id/deliveries?size=2&page=2',
          as: browser);
      expect(
          page.json.keys, unorderedEquals(['items', 'page', 'size', 'total']));
      expect(page.json['items'], hasLength(1));
      // Not attempted yet, as a document stored before durationMs existed.
      expect(page.json['items'].single['durationMs'], isNull);
      expect(page.json['items'].single['payload'], '{}');
      expect(page.json['total'], 3);
      expect(page.json['page'], 2);

      final audit = await send('GET', '/webapi/audit?size=1', as: browser);
      expect(
          audit.json.keys, unorderedEquals(['items', 'page', 'size', 'total']));
      expect(audit.json['items'], hasLength(1));
      expect(audit.json['total'], greaterThan(1));
    });
  });

  test('extreme pages are bounded on every paged route', () async {
    await harness.user('admin@example.com', Role.admin);
    final browser = await harness.apiLogIn('admin@example.com');
    final created = await send('POST', '/webapi/webhooks', as: browser, json: {
      'url': 'http://127.0.0.1:9/hook',
      'events': ['package.published'],
    });
    final id = created.json['webhook']['id'] as String;
    const huge = '922337203685477581';
    for (final path in [
      '/webapi/users',
      '/webapi/tokens',
      '/webapi/webhooks',
      '/webapi/webhooks/$id/deliveries',
      '/webapi/audit',
      '/webapi/v2/packages',
    ]) {
      for (final query in [
        'page=$huge&size=100',
        'page=$huge&size=$huge',
        'page=99999999999999999999999&size=-$huge',
        'page=100001',
      ]) {
        final reply = await send('GET', '$path?$query', as: browser);
        if (path == '/webapi/audit' && query.contains('size=')) {
          if (query.endsWith('size=100')) {
            expect(reply.json['page'], maxPage);
          } else {
            // The audit log refuses a size out of range instead.
            expect(reply.status, HttpStatus.badRequest);
            expect(reply.json['error']['code'], 'invalid_request');
          }
          continue;
        }
        expect(reply.status, HttpStatus.ok, reason: '$path?$query');
        expect(reply.json['items'], isEmpty, reason: '$path?$query');
        expect(reply.json['page'], maxPage, reason: '$path?$query');
        expect(reply.json['size'], inInclusiveRange(1, 200));
      }
    }
    final last = await send('GET', '/webapi/users?page=100000', as: browser);
    expect(last.json['page'], 100000);
    // The former web UI route, zero-based.
    final legacy = await send('GET', '/webapi/packages?page=$huge&size=$huge');
    expect(legacy.status, HttpStatus.ok);
    expect(legacy.json['data']['packages'], isEmpty);
  });

  test('a size that is not a positive integer is the default size', () async {
    await harness.user('admin@example.com', Role.admin);
    final browser = await harness.apiLogIn('admin@example.com');
    final created = await send('POST', '/webapi/webhooks', as: browser, json: {
      'url': 'http://127.0.0.1:9/hook',
      'events': ['package.published'],
    });
    final id = created.json['webhook']['id'] as String;
    for (final path in [
      '/webapi/users',
      '/webapi/tokens',
      '/webapi/webhooks',
      '/webapi/webhooks/$id/deliveries',
      '/webapi/v2/packages',
    ]) {
      final plain = await send('GET', path, as: browser);
      expect(plain.status, HttpStatus.ok, reason: path);
      expect(plain.json['size'], 20, reason: path);
      for (final size in ['0', '-1', 'abc', '']) {
        final reply = await send('GET', '$path?size=$size', as: browser);
        expect(reply.status, HttpStatus.ok, reason: '$path?size=$size');
        expect(reply.json['size'], 20, reason: '$path?size=$size');
      }
    }
  });

  group('every change of the client', () {
    test('accepts a session with X-CSRF-Token and refuses one without',
        () async {
      final admin = await harness.user('admin@example.com', Role.admin);
      final publisher = await harness.user('pub@example.com', Role.publisher);
      await harness.user('other@example.com', Role.publisher);
      final secret = await harness.token(publisher);
      await harness.publish('alpha', '1.0.0', bearer: secret);
      await harness.publish('alpha', '1.1.0', bearer: secret);
      await harness.publish('beta', '1.0.0', bearer: secret);
      final browser = await harness.apiLogIn('admin@example.com');
      final reader = await harness.user('reader@example.com', Role.reader);
      final someToken = await harness.accounts.createToken(admin, name: 'x');

      final store = WebhookStore(harness.db);
      final hook = await store.insert(
          url: Uri.parse('http://127.0.0.1:9/hook'),
          events: ['package.published'],
          description: '',
          secret: 's');
      await store.enqueue([hook],
          event: 'package.published', eventId: 'e', payload: '{}');
      final delivery = (await store.deliveries(hook.id)).single;

      // In order, so that each change is still possible when it is made.
      final changes = <(String, String, Object?)>[
        ('POST', '/webapi/tokens', {'name': 'ci'}),
        ('DELETE', '/webapi/tokens/${someToken.token.id}', null),
        (
          'POST',
          '/webapi/users',
          {'email': 'new@example.com', 'role': 'reader'}
        ),
        ('PATCH', '/webapi/users/${reader.id}', {'displayName': 'R'}),
        (
          'POST',
          '/webapi/users/${reader.id}/password',
          {'password': 'another-long-password'}
        ),
        (
          'POST',
          '/webapi/webhooks',
          {
            'url': 'http://127.0.0.1:9/other',
            'events': ['package.published'],
          }
        ),
        ('PATCH', '/webapi/webhooks/${hook.id}', {'description': 'd'}),
        ('POST', '/webapi/webhooks/${hook.id}/secret', null),
        (
          'POST',
          '/webapi/webhooks/${hook.id}/deliveries/${delivery.id}/redeliver',
          null
        ),
        ('POST', '/api/packages/alpha/versions/1.0.0/retract', null),
        ('POST', '/api/packages/alpha/versions/1.0.0/unretract', null),
        ('PUT', '/api/packages/alpha/discontinue', {'isDiscontinued': true}),
        (
          'POST',
          '/api/packages/alpha/uploaders',
          {'email': 'other@example.com'}
        ),
        ('DELETE', '/api/packages/alpha/uploaders/other%40example.com', null),
        ('PUT', '/api/packages/alpha/owner', {'email': 'other@example.com'}),
        ('DELETE', '/api/packages/alpha/versions/1.0.0', null),
        ('DELETE', '/api/packages/beta', null),
        ('DELETE', '/webapi/webhooks/${hook.id}', null),
        (
          'POST',
          '/webapi/me/password',
          {
            'currentPassword': harnessPassword,
            'newPassword': harnessPassword,
          }
        ),
        ('POST', '/webapi/logout', null),
      ];
      for (final (method, path, body) in changes) {
        final refused = await harness.send(method, path,
            as: browser, json: body ?? const <String, Object>{}, csrf: false);
        expect(refused.status, HttpStatus.forbidden,
            reason: '$method $path without the header: ${refused.body}');
        expect(refused.json['error']['code'], 'csrf_failed');
        expect(refused.json, {
          'error': {'code': 'csrf_failed', 'message': isA<String>()},
        });
        expectResponse(method, path, refused.status, refused.json);

        final accepted = await harness.send(method, path,
            as: browser, json: body ?? const <String, Object>{});
        expect(accepted.status, inInclusiveRange(200, 299),
            reason: '$method $path: ${accepted.body}');
        expect(accepted.headers['content-type'], contains('json'),
            reason: '$method $path');
        expectResponse(method, path, accepted.status, accepted.json);
      }

      final package = await harness.packageDocument('alpha');
      expect(package!['uploaders'], ['other@example.com']);
      expect(await harness.packageDocument('beta'), isNull);
    });

    test('a wrong token is refused like a missing one', () async {
      await harness.user('admin@example.com', Role.admin);
      final browser = await harness.apiLogIn('admin@example.com');
      final reply = await harness.send('POST', '/webapi/tokens', json: {
        'name': 'x'
      }, headers: {
        'cookie': '$sessionCookieName=${browser.cookie}',
        'x-csrf-token': 'not-${browser.csrf}',
      });
      expect(reply.status, HttpStatus.forbidden);
      expect(reply.json['error']['code'], 'csrf_failed');
    });

    test('a Bearer token needs no CSRF header', () async {
      final admin = await harness.user('admin@example.com', Role.admin);
      final secret = await harness.token(admin);
      final reply = await harness
          .send('POST', '/webapi/tokens', bearer: secret, json: {'name': 'x'});
      expect(reply.status, HttpStatus.created);
    });

    test('adding an uploader still takes the form of dart pub', () async {
      final publisher = await harness.user('pub@example.com', Role.publisher);
      await harness.user('other@example.com', Role.publisher);
      final secret = await harness.token(publisher);
      await harness.publish('alpha', '1.0.0', bearer: secret);
      final reply = await harness.send('POST', '/api/packages/alpha/uploaders',
          bearer: secret, form: {'email': 'other@example.com'});
      expect(reply.status, HttpStatus.ok, reason: reply.body);
      expect((await harness.packageDocument('alpha'))!['uploaders'],
          containsAll(['pub@example.com', 'other@example.com']));
      final missing = await harness.send(
          'POST', '/api/packages/alpha/uploaders',
          bearer: secret, json: {'mail': 'x'});
      expect(missing.status, HttpStatus.badRequest);
      expect(missing.json['error'],
          {'code': 'invalid_request', 'message': 'email is required'});
    });
  });
}
