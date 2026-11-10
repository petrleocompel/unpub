import 'dart:io';

import 'package:test/test.dart';
import 'package:unpub/unpub.dart';

import 'harness.dart';

/// A sample line of the text format 0.0.4.
final _sample = RegExp(r'^([a-zA-Z_:][a-zA-Z0-9_:]*)'
    r'(\{([a-zA-Z_][a-zA-Z0-9_]*="(?:\\.|[^"\\])*"'
    r'(?:,[a-zA-Z_][a-zA-Z0-9_]*="(?:\\.|[^"\\])*")*)?\})?'
    r' (-?[0-9]+(?:\.[0-9]+)?(?:e[+-]?[0-9]+)?|\+Inf|-Inf|NaN)$');

/// The samples of an exposition by name, checking every line on the way.
Map<String, List<(Map<String, String>, String)>> parse(String text) {
  final samples = <String, List<(Map<String, String>, String)>>{};
  final typed = <String>{};
  expect(text, endsWith('\n'));
  for (final line in text.split('\n')..removeLast()) {
    if (line.startsWith('# HELP ')) continue;
    if (line.startsWith('# TYPE ')) {
      final [name, type] = line.substring(7).split(' ');
      expect(['counter', 'gauge', 'histogram'], contains(type), reason: line);
      expect(typed.add(name), isTrue, reason: 'TYPE twice: $line');
      continue;
    }
    final match = _sample.firstMatch(line);
    expect(match, isNotNull, reason: 'not a sample: $line');
    final name = match![1]!;
    final family = name.replaceFirst(RegExp(r'_(bucket|sum|count)$'), '');
    expect(typed.contains(name) || typed.contains(family), isTrue,
        reason: 'no TYPE before $line');
    final labels = <String, String>{
      for (final label
          in RegExp(r'([a-zA-Z_][a-zA-Z0-9_]*)="((?:\\.|[^"\\])*)"')
              .allMatches(match[3] ?? ''))
        label[1]!: label[2]!,
    };
    samples.putIfAbsent(name, () => []).add((labels, match[4]!));
  }
  return samples;
}

void main() {
  final h = Harness()..install();

  App appWith(String yaml,
          {ReadAccess readAccess = ReadAccess.public, Metrics? metrics}) =>
      App(
        metaStore: h.metaStore,
        packageStore: h.packageStore,
        authenticator:
            ChainAuthenticator([ApiTokenAuthenticator(h.accountStore)]),
        readAccess: readAccess,
        auditStore: h.audit,
        config: Config.parse(yaml, environment: const {}),
        metrics: metrics,
      );

  late String adminToken;
  late String ownerToken;

  setUp(() async {
    adminToken = await h.token(await h.user('admin@b.c', Role.admin));
    ownerToken = await h.token(await h.user('owner@b.c', Role.publisher));
  });

  Future<Reply> scrape({String? bearer, App? using}) =>
      h.send('GET', '/metrics', bearer: bearer, using: using);

  group('the exposition', () {
    test('is valid text format 0.0.4', () async {
      await h.publish('alpha', '1.0.0', bearer: ownerToken);
      final reply = await scrape();
      expect(reply.status, HttpStatus.ok);
      expect(reply.headers['content-type'],
          'text/plain; version=0.0.4; charset=utf-8');
      final samples = parse(reply.body);
      expect(
          samples['unpub_build_info']!.single.$1, {'version': packageVersion});
      expect(samples['unpub_mongo_up']!.single.$2, '1');
      expect(samples['unpub_packages']!.single.$2, '1');
      expect(samples['unpub_versions']!.single.$2, '1');
      expect(
          int.parse(samples['unpub_storage_bytes']!.single.$2), greaterThan(0));
      expect(samples['unpub_publishes_total']!.single.$2, '1');
      expect(int.parse(samples['process_start_time_seconds']!.single.$2),
          greaterThan(1700000000));
    });

    test('labels requests by route pattern, not by path', () async {
      await h.publish('alpha', '1.0.0', bearer: ownerToken);
      for (final name in ['alpha', 'beta', 'gamma']) {
        await h.send('GET', '/api/packages/$name');
      }
      await h.send('GET', '/no/such/$adminToken');
      await h.send('HEAD', '/api/packages/alpha');
      final samples = parse((await scrape()).body);
      final requests = samples['unpub_http_requests_total']!;
      final routes = {for (final (labels, _) in requests) labels['route']};
      expect(routes, contains('/api/packages/<name>'));
      expect(routes, contains(unmatchedRoute));
      expect(routes.any((route) => route!.contains('alpha')), isFalse);
      expect(routes.any((route) => route!.contains(adminToken)), isFalse);
      final listings = requests
          .where((sample) =>
              sample.$1['route'] == '/api/packages/<name>' &&
              sample.$1['method'] == 'GET')
          .toList();
      // alpha is found, beta and gamma redirect upstream.
      expect({for (final s in listings) s.$1['status']: s.$2},
          {'200': '1', '302': '2'});
      expect(
          requests.any((s) =>
              s.$1['method'] == 'HEAD' &&
              s.$1['route'] == '/api/packages/<name>'),
          isTrue);
      expect(
          requests.any((s) =>
              s.$1['route'] == '/api/packages/versions/newUpload' &&
              s.$1['method'] == 'POST'),
          isTrue);
    });

    test('has cumulative duration buckets', () async {
      await h.send('GET', '/healthz');
      await h.send('GET', '/healthz');
      final samples = parse((await scrape()).body);
      final buckets = samples['unpub_http_request_duration_seconds_bucket']!
          .where((s) => s.$1['route'] == '/healthz')
          .toList();
      expect([for (final b in buckets) b.$1['le']],
          ['0.005', '0.025', '0.1', '0.5', '2.5', '10.0', '+Inf']);
      final counts = [for (final b in buckets) int.parse(b.$2)];
      for (var i = 1; i < counts.length; i++) {
        expect(counts[i], greaterThanOrEqualTo(counts[i - 1]));
      }
      expect(counts.last, 2);
      final count = samples['unpub_http_request_duration_seconds_count']!
          .firstWhere((s) => s.$1['route'] == '/healthz');
      expect(count.$2, '2');
    });

    test('counts pub client downloads only', () async {
      await h.publish('alpha', '1.0.0', bearer: ownerToken);
      const path = '/packages/alpha/versions/1.0.0.tar.gz';
      const pub = {'user-agent': 'Dart pub 3.12.0'};
      await h.send('GET', path, headers: pub);
      await h.send('HEAD', path, headers: pub);
      await h.send('GET', path);
      final samples = parse((await scrape()).body);
      expect(samples['unpub_downloads_total']!.single.$2, '1');
    });

    test('counts webhook deliveries and upstream fetches by result', () {
      final metrics = Metrics()
        ..countWebhookDelivery('success')
        ..countWebhookDelivery('success')
        ..countWebhookDelivery('retry')
        ..countUpstreamFetch('not_found');
      final samples =
          parse(metrics.render(const MetricsSnapshot(mongoUp: false)));
      expect({
        for (final s in samples['unpub_webhook_deliveries_total']!)
          s.$1['result']: s.$2
      }, {
        'success': '2',
        'retry': '1'
      });
      expect(samples['unpub_upstream_fetches_total']!.single.$1,
          {'result': 'not_found'});
      expect(samples['unpub_mongo_up']!.single.$2, '0');
      expect(samples.containsKey('unpub_packages'), isFalse);
    });

    test('escapes label values', () {
      final metrics = Metrics()
        ..countRequest('/a"b\\c\nd', 'GET', 200, Duration.zero);
      final text = metrics.render(const MetricsSnapshot(mongoUp: true));
      expect(text, contains(r'route="/a\"b\\c\nd"'));
      parse(text);
    });
  });

  group('access', () {
    test('is open while reads are public and no token is set', () async {
      expect((await scrape(using: appWith(''))).status, HttpStatus.ok);
    });

    test('needs metrics.token once one is set', () async {
      final app = appWith('metrics:\n  token: scrape-secret\n');
      final anonymous = await scrape(using: app);
      expect(anonymous.status, HttpStatus.unauthorized);
      expect(anonymous.headers['www-authenticate'], contains('Bearer'));
      expect((await scrape(bearer: 'wrong', using: app)).status,
          HttpStatus.unauthorized);
      expect((await scrape(bearer: 'scrape-secret', using: app)).status,
          HttpStatus.ok);
      expect(
          (await scrape(bearer: adminToken, using: app)).status, HttpStatus.ok);
      expect((await scrape(bearer: ownerToken, using: app)).status,
          HttpStatus.forbidden);
    });

    test('needs a token or an administrator when reads need one', () async {
      final open = appWith('', readAccess: ReadAccess.authenticated);
      expect((await scrape(using: open)).status, HttpStatus.unauthorized);
      expect((await scrape(bearer: adminToken, using: open)).status,
          HttpStatus.ok);
      final reader = await h.token(await h.user('r@b.c', Role.reader));
      expect((await scrape(bearer: reader, using: open)).status,
          HttpStatus.forbidden);
      final publishOnly = await h.token(
          await h.accounts.requireUserByEmail('admin@b.c'),
          scopes: {Scope.publish});
      expect((await scrape(bearer: publishOnly, using: open)).status,
          HttpStatus.forbidden);

      final tokened = appWith('metrics:\n  token: scrape-secret\n',
          readAccess: ReadAccess.authenticated);
      expect((await scrape(bearer: 'scrape-secret', using: tokened)).status,
          HttpStatus.ok);
      // The metrics token opens nothing else.
      expect(
          (await h.send('GET', '/api/packages/alpha',
                  bearer: 'scrape-secret', using: tokened))
              .status,
          HttpStatus.unauthorized);
    });

    test('is a 404 when switched off', () async {
      final app = appWith('metrics:\n  enabled: false\n');
      expect((await scrape(using: app)).status, HttpStatus.notFound);
    });

    test('the token is a secret of the configuration', () {
      final config = Config.parse(null,
          environment: const {'UNPUB_METRICS_TOKEN': 'from-env'});
      expect(config.metrics.token, 'from-env');
      expect(() => Config.parse('metrics:\n  token: "has space"\n'),
          throwsA(isA<ConfigException>()));
    });
  });

  test('a cached value is computed again only when old', () async {
    var now = DateTime(2026);
    var computed = 0;
    final value = CachedValue(() async => ++computed,
        maxAge: const Duration(minutes: 10), clock: () => now);
    expect(await value.get(), 1);
    now = now.add(const Duration(minutes: 9));
    expect(await value.get(), 1);
    now = now.add(const Duration(minutes: 2));
    expect(await value.get(), 2);
  });
}
