import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:unpub/unpub.dart';

import 'harness.dart';

/// A request the receiver got.
class Received {
  final String path;
  final Map<String, String> headers;
  final List<int> body;

  Received(this.path, this.headers, this.body);

  Map<String, dynamic> get json =>
      jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
}

/// A local HTTP server that answers with the next of [answers], the last one
/// repeating.
class Receiver {
  late HttpServer server;
  final received = <Received>[];
  List<(int, String, Map<String, String>)> answers = [(200, 'ok', const {})];

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = await request.fold<List<int>>([], (a, b) => a..addAll(b));
      received.add(Received(
          request.uri.path,
          {
            for (final name in [
              'content-type',
              'user-agent',
              'x-unpub-event',
              'x-unpub-delivery',
              'x-unpub-signature',
            ])
              if (request.headers.value(name) case final value?) name: value,
          },
          body));
      final (status, text, headers) =
          answers[(received.length - 1).clamp(0, answers.length - 1)];
      request.response.statusCode = status;
      headers.forEach(request.response.headers.set);
      request.response.write(text);
      await request.response.close();
    });
  }

  Uri url([String path = '/hook']) =>
      Uri.parse('http://127.0.0.1:${server.port}$path');

  Future<void> stop() => server.close(force: true);
}

void main() {
  late WebhookService service;
  late WebhookStore store;

  WebhookService newService(Harness h,
          {WebhooksConfig config = const WebhooksConfig(
              allowHttp: true,
              allowPrivateNetworks: true,
              maxAttempts: 3,
              timeout: Duration(seconds: 2)),
          Future<List<InternetAddress>> Function(String)? lookup}) =>
      WebhookService(WebhookStore(h.db),
          config: config,
          audit: h.audit,
          retryDelays: const [Duration(milliseconds: 40)],
          lookup: lookup);

  final h = Harness(builder: (h) {
    store = WebhookStore(h.db);
    service = newService(h);
    return h.buildApp(webhooks: service);
  })
    ..install();

  final receiver = Receiver();
  setUpAll(receiver.start);
  tearDownAll(receiver.stop);

  late String adminToken;
  late String ownerToken;

  setUp(() async {
    receiver.received.clear();
    receiver.answers = [(200, 'ok', const {})];
    await store.ensureIndexes();
    adminToken = await h.token(await h.user('admin@b.c', Role.admin));
    ownerToken = await h.token(await h.user('owner@b.c', Role.publisher));
  });

  Future<(Webhook, String)> addHook(
      {Uri? url, List<String> events = webhookEvents}) async {
    final reply =
        await h.send('POST', '/webapi/webhooks', bearer: adminToken, json: {
      'url': '${url ?? receiver.url()}',
      'events': events,
      'description': 'CI',
    });
    expect(reply.status, HttpStatus.created, reason: reply.body);
    final hook = (await store.find(reply.json['webhook']['id'] as String))!;
    return (hook, reply.json['secret'] as String);
  }

  /// Delivers everything due with [using], then what falls due within
  /// [wait].
  Future<void> drain({WebhookService? using, Duration? wait}) async {
    final worker = using ?? service;
    while (await worker.deliverDue()) {}
    if (wait != null) {
      await Future<void>.delayed(wait);
      while (await worker.deliverDue()) {}
    }
  }

  Future<List<Delivery>> deliveries(Webhook hook) => store.deliveries(hook.id);

  group('delivery', () {
    test('is signed with the secret', () async {
      final (hook, secret) = await addHook();
      expect(secret, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      expect(hook.secret, secret);
      await h.publish('alpha', '1.0.0', bearer: ownerToken);
      await drain();

      final request = receiver.received.single;
      expect(request.path, '/hook');
      final expected =
          Hmac(sha256, utf8.encode(secret)).convert(request.body).toString();
      expect(request.headers['x-unpub-signature'], 'sha256=$expected');
      expect(request.headers['content-type'], startsWith('application/json'));
      expect(request.headers['x-unpub-event'], 'package.published');
      expect(request.headers['user-agent'], 'unpub/$packageVersion');

      final body = request.json;
      expect(body['event'], 'package.published');
      expect(body['package'], 'alpha');
      expect(body['version'], '1.0.0');
      expect(body['actor'], 'owner@b.c');
      expect(body['id'], hasLength(24));
      expect(DateTime.parse(body['at'] as String).isUtc, isTrue);
      expect(body['data']['sha256'], hasLength(64));

      final delivery = (await deliveries(hook)).single;
      expect(request.headers['x-unpub-delivery'], delivery.id);
      expect(delivery.status, DeliveryStatus.succeeded);
      expect(delivery.attempt, 1);
      expect(delivery.responseStatus, 200);
      expect(delivery.responseBody, 'ok');
      expect(delivery.finishedAt, isNotNull);
    });

    test('is tried again after a 500', () async {
      receiver.answers = [(500, 'down', const {}), (204, '', const {})];
      final (hook, _) = await addHook();
      await h.publish('alpha', '1.0.0', bearer: ownerToken);
      await drain();
      var delivery = (await deliveries(hook)).single;
      expect(delivery.status, DeliveryStatus.pending);
      expect(delivery.attempt, 1);
      expect(delivery.responseStatus, 500);
      expect(delivery.responseBody, 'down');
      expect(delivery.error, contains('500'));

      // Not due before the delay.
      expect(await service.deliverDue(), isFalse);
      await drain(wait: const Duration(milliseconds: 150));
      delivery = (await deliveries(hook)).single;
      expect(delivery.status, DeliveryStatus.succeeded);
      expect(delivery.attempt, 2);
      expect(receiver.received, hasLength(2));
      expect(receiver.received[0].body, receiver.received[1].body);
    });

    test('gives up after webhooks.maxAttempts', () async {
      receiver.answers = [(503, 'no', const {})];
      final (hook, _) = await addHook();
      await h.publish('alpha', '1.0.0', bearer: ownerToken);
      for (var i = 0; i < 4; i++) {
        await drain(wait: const Duration(milliseconds: 150));
      }
      final delivery = (await deliveries(hook)).single;
      expect(delivery.status, DeliveryStatus.failed);
      expect(delivery.attempt, 3);
      expect(delivery.finishedAt, isNotNull);
      expect(receiver.received, hasLength(3));
    });

    test('does not follow a redirect', () async {
      receiver.answers = [
        (302, '', {'location': '/elsewhere'})
      ];
      final (hook, _) = await addHook();
      await h.publish('alpha', '1.0.0', bearer: ownerToken);
      await drain();
      final delivery = (await deliveries(hook)).single;
      expect(delivery.responseStatus, 302);
      expect(delivery.error, contains('redirect'));
      expect(delivery.status, DeliveryStatus.pending);
      expect([for (final r in receiver.received) r.path], ['/hook']);
    });

    test('keeps at most 1 KiB of the answer', () async {
      receiver.answers = [(200, 'x' * 5000, const {})];
      final (hook, _) = await addHook();
      await h.publish('alpha', '1.0.0', bearer: ownerToken);
      await drain();
      expect((await deliveries(hook)).single.responseBody, hasLength(1024));
    });

    test('times out', () async {
      final slow = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => slow.close(force: true));
      slow.listen((request) {});
      service = newService(h,
          config: const WebhooksConfig(
              allowHttp: true,
              allowPrivateNetworks: true,
              timeout: Duration(milliseconds: 300)));
      final app = h.buildApp(webhooks: service);
      final (hook, _) =
          await addHook(url: Uri.parse('http://127.0.0.1:${slow.port}/'));
      await h.publish('alpha', '1.0.0', bearer: ownerToken, using: app);
      await drain();
      final delivery = (await deliveries(hook)).single;
      expect(delivery.status, DeliveryStatus.pending);
      expect(delivery.error, contains('no answer'));
    });

    test('is sent once although two instances share the queue', () async {
      final (hook, _) = await addHook();
      await h.publish('alpha', '1.0.0', bearer: ownerToken);
      final other = newService(h);
      final results =
          await Future.wait([service.deliverDue(), other.deliverDue()]);
      expect(results.where((claimed) => claimed), hasLength(1));
      expect(receiver.received, hasLength(1));
      expect((await deliveries(hook)).single.status, DeliveryStatus.succeeded);
    });

    test('goes only to enabled webhooks that subscribe', () async {
      final (all, _) = await addHook();
      final (retractions, _) =
          await addHook(url: receiver.url('/r'), events: ['version.retracted']);
      final (disabled, _) = await addHook(url: receiver.url('/off'));
      await h.send('PATCH', '/webapi/webhooks/${disabled.id}',
          bearer: adminToken, json: {'enabled': false});

      await h.publish('alpha', '1.0.0', bearer: ownerToken);
      await h.send('POST', '/api/packages/alpha/versions/1.0.0/retract',
          bearer: ownerToken);
      await drain();
      expect((await deliveries(all)).map((d) => d.event),
          unorderedEquals(['package.published', 'version.retracted']));
      expect((await deliveries(retractions)).single.event, 'version.retracted');
      expect(await deliveries(disabled), isEmpty);
    });

    test('reports every package event', () async {
      final (hook, _) = await addHook();
      await h.publish('alpha', '1.0.0', bearer: ownerToken);
      await h.publish('alpha', '1.1.0', bearer: ownerToken);
      Future<Reply> post(String path) =>
          h.send('POST', path, bearer: ownerToken);
      await post('/api/packages/alpha/versions/1.0.0/retract');
      await post('/api/packages/alpha/versions/1.0.0/unretract');
      await h.send('PUT', '/api/packages/alpha/discontinue',
          bearer: ownerToken,
          json: {'isDiscontinued': true, 'replacedBy': 'beta'});
      // The same state again is not an event.
      await h.send('PUT', '/api/packages/alpha/discontinue',
          bearer: ownerToken,
          json: {'isDiscontinued': true, 'replacedBy': 'beta'});
      await h.send('PUT', '/api/packages/alpha/discontinue',
          bearer: ownerToken, json: {'isDiscontinued': false});
      await h.send('DELETE', '/api/packages/alpha/versions/1.0.0',
          bearer: adminToken);
      await h.send('DELETE', '/api/packages/alpha', bearer: adminToken);
      await drain();
      final bodies = [for (final r in receiver.received) r.json];
      expect([
        for (final b in bodies) b['event']
      ], [
        'package.published',
        'package.published',
        'version.retracted',
        'version.unretracted',
        'package.discontinued',
        'package.continued',
        'version.deleted',
        'package.deleted',
      ]);
      expect(bodies[4]['data'], {'replacedBy': 'beta'});
      expect(bodies[4].containsKey('version'), isFalse);
      expect(bodies[6]['version'], '1.0.0');
      expect(bodies[6]['actor'], 'admin@b.c');
      expect(bodies[7]['data']['versions'], ['1.1.0']);
      expect((await deliveries(hook)), hasLength(8));
    });

    test('of a deleted webhook is dropped with it', () async {
      final (hook, _) = await addHook();
      await h.publish('alpha', '1.0.0', bearer: ownerToken);
      await h.send('DELETE', '/webapi/webhooks/${hook.id}', bearer: adminToken);
      expect(await service.deliverDue(), isFalse);
      expect(receiver.received, isEmpty);
    });

    test('runs in the background until stopped', () async {
      service = newService(h);
      final app = h.buildApp(webhooks: service);
      await addHook();
      service.start();
      await h.publish('alpha', '1.0.0', bearer: ownerToken, using: app);
      for (var i = 0; i < 100 && receiver.received.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await service.stop();
      expect(receiver.received, hasLength(1));
      await h.publish('alpha', '1.1.0', bearer: ownerToken, using: app);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(receiver.received, hasLength(1));
    });

    test('is not queued when webhooks are switched off', () async {
      service = newService(h, config: const WebhooksConfig(enabled: false));
      final app = h.buildApp(webhooks: service);
      final (hook, _) = await addHook(url: Uri.parse('https://example.com/'));
      await h.publish('alpha', '1.0.0', bearer: ownerToken, using: app);
      expect(await deliveries(hook), isEmpty);
    });
  });

  group('addresses', () {
    WebhookService guarded(
            {Future<List<InternetAddress>> Function(String)? lookup}) =>
        newService(h,
            config: const WebhooksConfig(allowHttp: true), lookup: lookup);

    test('a private address is refused for good', () async {
      service = guarded();
      final app = h.buildApp(webhooks: service);
      final (hook, _) = await addHook();
      await h.publish('alpha', '1.0.0', bearer: ownerToken, using: app);
      await drain();
      final delivery = (await deliveries(hook)).single;
      expect(delivery.status, DeliveryStatus.failed);
      expect(delivery.attempt, 1);
      expect(delivery.error, contains('private address 127.0.0.1'));
      expect(receiver.received, isEmpty);
    });

    test('a name resolving to a private address is refused', () async {
      service = guarded(
          lookup: (host) async => [
                InternetAddress('93.184.216.34'),
                InternetAddress('10.1.2.3'),
              ]);
      final app = h.buildApp(webhooks: service);
      final (hook, _) =
          await addHook(url: Uri.parse('http://hooks.example.test/x'));
      await h.publish('alpha', '1.0.0', bearer: ownerToken, using: app);
      await drain();
      final delivery = (await deliveries(hook)).single;
      expect(delivery.status, DeliveryStatus.failed);
      expect(delivery.error, contains('10.1.2.3'));
    });

    test('the connection goes to the address that was checked', () async {
      // The name resolves to the receiver, which must get the request with
      // the name in the Host header.
      service =
          newService(h, lookup: (host) async => [InternetAddress.loopbackIPv4]);
      final app = h.buildApp(webhooks: service);
      await addHook(
          url: Uri.parse('http://hooks.example.test:${receiver.server.port}/'));
      await h.publish('alpha', '1.0.0', bearer: ownerToken, using: app);
      await drain();
      expect(receiver.received, hasLength(1));
    });

    test('private ranges', () {
      for (final address in [
        '127.0.0.1',
        '10.0.0.1',
        '172.16.0.1',
        '172.31.255.255',
        '192.168.1.1',
        '169.254.169.254',
        '100.64.0.1',
        '0.0.0.0',
        '224.0.0.1',
        '255.255.255.255',
        '::1',
        '::',
        'fe80::1',
        'fc00::1',
        'fd12:3456::1',
        'ff02::1',
        '::ffff:127.0.0.1',
        '::ffff:10.0.0.1',
        '64:ff9b::a00:1',
      ]) {
        expect(isPrivateAddress(InternetAddress(address)), isTrue,
            reason: address);
      }
      for (final address in [
        '93.184.216.34',
        '172.32.0.1',
        '8.8.8.8',
        '2606:4700::1111',
        '::ffff:8.8.8.8',
      ]) {
        expect(isPrivateAddress(InternetAddress(address)), isFalse,
            reason: address);
      }
    });

    test('URLs are checked when a webhook is added', () async {
      service = newService(h, config: const WebhooksConfig());
      final app = h.buildApp(webhooks: service);
      Future<Reply> add(Object body) => h.send('POST', '/webapi/webhooks',
          bearer: adminToken, json: body, using: app);
      final events = ['package.published'];
      for (final url in [
        'http://example.com/',
        'ftp://example.com/',
        'https://user:pw@example.com/',
        'https:///path',
        'not a url',
      ]) {
        final reply = await add({'url': url, 'events': events});
        expect(reply.status, HttpStatus.badRequest, reason: url);
      }
      expect((await add({'url': 'https://example.com/', 'events': []})).status,
          HttpStatus.badRequest);
      final unknown = await add({
        'url': 'https://example.com/',
        'events': ['nope']
      });
      expect(unknown.json['error']['message'], contains('nope'));
      expect(
          (await add({'url': 'https://example.com/', 'events': events})).status,
          HttpStatus.created);
    });
  });

  group('the API', () {
    test('is for administrators', () async {
      final reader = await h.token(await h.user('r@b.c', Role.reader));
      for (final (method, path) in [
        ('GET', '/webapi/webhooks'),
        ('POST', '/webapi/webhooks'),
      ]) {
        expect((await h.send(method, path, json: {})).status,
            HttpStatus.unauthorized);
        expect(
            (await h.send(method, path, bearer: ownerToken, json: {})).status,
            HttpStatus.forbidden);
        expect((await h.send(method, path, bearer: reader, json: {})).status,
            HttpStatus.forbidden);
      }
    });

    test('never lists the secret', () async {
      final (hook, secret) = await addHook();
      final list = await h.send('GET', '/webapi/webhooks', bearer: adminToken);
      expect(list.status, HttpStatus.ok);
      expect(list.body, isNot(contains(secret)));
      expect(list.json['webhooks'].single['id'], hook.id);
      final one = await h.send('GET', '/webapi/webhooks/${hook.id}',
          bearer: adminToken);
      expect(one.body, isNot(contains(secret)));
      expect(
          one.json['deliveries'], {'pending': 0, 'succeeded': 0, 'failed': 0});
    });

    test('changes, rotates, redelivers and deletes', () async {
      final (hook, secret) = await addHook();
      final patched = await h.send('PATCH', '/webapi/webhooks/${hook.id}',
          bearer: adminToken,
          json: {
            'events': ['package.published'],
            'description': 'builds',
          });
      expect(patched.status, HttpStatus.ok, reason: patched.body);
      expect(patched.json['webhook']['events'], ['package.published']);

      final rotated = await h.send('POST', '/webapi/webhooks/${hook.id}/secret',
          bearer: adminToken);
      final newSecret = rotated.json['secret'] as String;
      expect(newSecret, isNot(secret));

      await h.publish('alpha', '1.0.0', bearer: ownerToken);
      await drain();
      final first = receiver.received.single;
      expect(first.headers['x-unpub-signature'],
          WebhookService.signature(newSecret, first.body));

      final listed = await h.send(
          'GET', '/webapi/webhooks/${hook.id}/deliveries',
          bearer: adminToken);
      final delivery = listed.json['deliveries'].single;
      expect(delivery['status'], 'succeeded');
      expect(delivery['response']['status'], 200);
      expect(listed.body, isNot(contains(newSecret)));

      final again = await h.send('POST',
          '/webapi/webhooks/${hook.id}/deliveries/${delivery['id']}/redeliver',
          bearer: adminToken);
      expect(again.status, HttpStatus.ok, reason: again.body);
      await drain();
      expect(receiver.received, hasLength(2));
      expect(receiver.received[1].json['id'], first.json['id']);
      expect(receiver.received[1].headers['x-unpub-delivery'],
          isNot(first.headers['x-unpub-delivery']));
      final redelivered = (await deliveries(hook)).first;
      expect(redelivered.redeliveryOf, delivery['id']);

      expect(
          (await h.send('POST',
                  '/webapi/webhooks/${hook.id}/deliveries/${'0' * 24}/redeliver',
                  bearer: adminToken))
              .status,
          HttpStatus.notFound);

      final deleted = await h.send('DELETE', '/webapi/webhooks/${hook.id}',
          bearer: adminToken);
      expect(deleted.status, HttpStatus.ok);
      expect(await store.find(hook.id), isNull);
      expect(await deliveries(hook), isEmpty);
      expect(
          (await h.send('GET', '/webapi/webhooks/${hook.id}',
                  bearer: adminToken))
              .status,
          HttpStatus.notFound);
      expect(
          (await h.send('GET', '/webapi/webhooks/nonsense', bearer: adminToken))
              .status,
          HttpStatus.notFound);

      final actions = [for (final e in await h.auditEvents()) e['action']];
      expect(
          actions,
          containsAll([
            'webhook.created',
            'webhook.updated',
            'webhook.secret_rotated',
            'webhook.redelivered',
            'webhook.deleted',
          ]));
      final events = await h.auditEvents();
      expect(events.toString(), isNot(contains(newSecret)));
      expect(events.toString(), isNot(contains(secret)));
    });
  });

  group('the admin pages', () {
    late Browser browser;

    setUp(() async {
      browser = await h.logIn('admin@b.c');
    });

    test('add a webhook and show its secret once', () async {
      final empty = await h.page('/admin/webhooks', as: browser);
      expect(empty.status, HttpStatus.ok);
      expect(empty.body, contains('No webhooks yet.'));
      expect(empty.body, contains('href="/admin/webhooks"'));

      final refused = await h.post('/admin/webhooks',
          as: browser,
          csrf: false,
          form: {'url': '${receiver.url()}', 'events': 'package.published'});
      expect(refused.status, HttpStatus.forbidden);
      expect(await store.list(), isEmpty);

      final invalid = await h.post('/admin/webhooks',
          as: browser, form: {'url': '${receiver.url()}'});
      expect(invalid.status, HttpStatus.badRequest);
      expect(invalid.body, contains('at least one event'));
      expect(invalid.body, contains('value="${receiver.url()}"'));

      final created = await h.post('/admin/webhooks', as: browser, form: {
        'url': '${receiver.url()}',
        'events': ['package.published', 'package.deleted'],
        'description': 'CI <builds>',
      });
      expect(created.status, HttpStatus.created, reason: created.body);
      final hook = (await store.list()).single;
      expect(created.body, contains(hook.secret));
      expect(hook.events, ['package.published', 'package.deleted']);

      final page = await h.page('/admin/webhooks/${hook.id}', as: browser);
      expect(page.body, isNot(contains(hook.secret)));
      expect(page.body, contains('CI &lt;builds&gt;'));
      final list = await h.page('/admin/webhooks', as: browser);
      expect(list.body, isNot(contains(hook.secret)));
      expect(list.body, contains('href="/admin/webhooks/${hook.id}"'));
    });

    test('disable, rotate, redeliver and delete', () async {
      final (hook, secret) = await addHook();
      final base = '/admin/webhooks/${hook.id}';

      final disabled = await h
          .post('$base/enabled', as: browser, form: {'enabled': 'false'});
      expect(disabled.status, HttpStatus.seeOther);
      expect((await store.find(hook.id))!.enabled, isFalse);
      await h.post('$base/enabled', as: browser, form: {'enabled': 'true'});
      expect((await store.find(hook.id))!.enabled, isTrue);

      final rotated = await h.post('$base/secret', as: browser);
      expect(rotated.status, HttpStatus.ok);
      final newSecret = (await store.find(hook.id))!.secret;
      expect(newSecret, isNot(secret));
      expect(rotated.body, contains(newSecret));

      receiver.answers = [(500, 'broken', const {})];
      service = newService(h,
          config: const WebhooksConfig(
              allowHttp: true, allowPrivateNetworks: true, maxAttempts: 1));
      final app = h.buildApp(webhooks: service);
      await h.publish('alpha', '1.0.0', bearer: ownerToken, using: app);
      await drain();
      final failed = (await deliveries(hook)).single;
      expect(failed.status, DeliveryStatus.failed);

      final page = await h.page(base, as: browser, using: app);
      expect(page.body, contains('Failed'));
      expect(page.body, contains('broken'));
      final redeliverPath = '$base/deliveries/${failed.id}/redeliver';
      expect(page.body, contains('action="$redeliverPath"'));

      receiver.answers = [(200, 'fine', const {})];
      final noToken =
          await h.post(redeliverPath, as: browser, csrf: false, using: app);
      expect(noToken.status, HttpStatus.forbidden);
      final queued = await h.post(redeliverPath, as: browser, using: app);
      expect(queued.status, HttpStatus.seeOther);
      expect(queued.location, '$base?done=redelivery-queued');
      await drain();
      expect((await deliveries(hook)).first.status, DeliveryStatus.succeeded);

      final deleted = await h.post('$base/delete', as: browser);
      expect(deleted.status, HttpStatus.seeOther);
      expect(deleted.location, '/admin/webhooks?done=webhook-deleted');
      expect(await store.find(hook.id), isNull);
      expect((await h.page(base, as: browser)).status, HttpStatus.notFound);
    });

    test('refuse everyone but administrators', () async {
      final (hook, _) = await addHook();
      final publisher = await h.logIn('owner@b.c');
      final base = '/admin/webhooks/${hook.id}';
      for (final path in ['/admin/webhooks', base]) {
        expect((await h.page(path, as: publisher)).status, HttpStatus.forbidden,
            reason: path);
      }
      for (final (path, form) in [
        (
          '/admin/webhooks',
          {'url': 'https://x.example/', 'events': 'package.published'}
        ),
        ('$base/enabled', {'enabled': 'false'}),
        ('$base/secret', const <String, Object>{}),
        ('$base/delete', const <String, Object>{}),
      ]) {
        expect((await h.post(path, as: publisher, form: form)).status,
            HttpStatus.forbidden,
            reason: path);
      }
      expect((await store.find(hook.id))!.enabled, isTrue);
    });
  });

  group('retention', () {
    Future<int?> ttl() async {
      final indexes =
          await h.db.collection(webhookDeliveryCollection).getIndexes();
      for (final index in indexes) {
        if (index['name'] == webhookDeliveryRetentionIndex) {
          return (index['expireAfterSeconds'] as num).toInt();
        }
      }
      return null;
    }

    test('follows webhooks.retentionDays', () async {
      await store.ensureIndexes(retention: const Duration(days: 30));
      expect(await ttl(), 30 * 86400);
      await store.ensureIndexes(retention: const Duration(days: 2));
      expect(await ttl(), 2 * 86400);
      await store.ensureIndexes();
      expect(await ttl(), isNull);
    });

    test('is configured with the webhooks section', () {
      final config = Config.parse(
          'webhooks:\n  maxAttempts: 2\n  timeout: 3s\n  allowHttp: true\n'
          '  retentionDays: 0\n',
          environment: const {'UNPUB_WEBHOOKS_ALLOW_PRIVATE_NETWORKS': 'true'});
      expect(config.webhooks.maxAttempts, 2);
      expect(config.webhooks.timeout, const Duration(seconds: 3));
      expect(config.webhooks.allowHttp, isTrue);
      expect(config.webhooks.allowPrivateNetworks, isTrue);
      expect(config.webhooks.retention, isNull);
      final defaults = Config.parse(null, environment: const {}).webhooks;
      expect(defaults.enabled, isTrue);
      expect(defaults.maxAttempts, 5);
      expect(defaults.timeout, const Duration(seconds: 10));
      expect(defaults.allowHttp, isFalse);
      expect(defaults.allowPrivateNetworks, isFalse);
      expect(defaults.retention, const Duration(days: 30));
      expect(() => Config.parse('webhooks:\n  maxAttempts: 0\n'),
          throwsA(isA<ConfigException>()));
    });
  });

  test('the delivery document never holds the secret', () async {
    final (hook, secret) = await addHook();
    await h.publish('alpha', '1.0.0', bearer: ownerToken);
    await drain();
    final stored =
        await h.db.collection(webhookDeliveryCollection).find().toList();
    expect(stored.toString(), isNot(contains(secret)));
    expect(hook.id, isNotEmpty);
  });
}
