import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart';
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

/// A file store whose size is known only once [gate] completes.
class _SlowStore extends FileStore {
  final Completer<void> gate;
  var measured = 0;

  _SlowStore(super.baseDir, this.gate);

  @override
  Future<int?> totalSize() async {
    measured++;
    await gate.future;
    return super.totalSize();
  }
}

void main() {
  final h = Harness()..install();

  App appWith(String yaml,
          {ReadAccess readAccess = ReadAccess.public,
          Metrics? metrics,
          PackageStore? packageStore}) =>
      App(
        metaStore: h.metaStore,
        packageStore: packageStore ?? h.packageStore,
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
      // The first scrape starts measuring the store.
      await scrape();
      await h.app.metricsSources.storage.idle;
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
      final measuredAt = int.parse(
          samples['unpub_storage_measured_timestamp_seconds']!.single.$2);
      expect(DateTime.now().millisecondsSinceEpoch ~/ 1000 - measuredAt,
          inInclusiveRange(0, 60));
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

    test('bounds the method and status labels', () async {
      for (final method in ['PROPFIND', 'BREW', 'X$adminToken', 'get']) {
        await h.send(method, '/healthz');
      }
      await h.send('OPTIONS', '/api/packages/alpha');
      final requests =
          parse((await scrape()).body)['unpub_http_requests_total']!;
      final methods = {for (final (labels, _) in requests) labels['method']};
      expect(methods, containsAll(['GET', 'OPTIONS', otherMethod]));
      expect(methods.difference({...metricMethods, otherMethod}), isEmpty);
      expect(
          requests.firstWhere((s) => s.$1['method'] == otherMethod).$1['route'],
          unmatchedRoute);
      // Unknown methods share one series per route and status.
      expect(
          requests
              .where((s) =>
                  s.$1['method'] == otherMethod && s.$1['status'] == '404')
              .single
              .$2,
          '3');

      final metrics = Metrics()
        ..countRequest('/x', 'delete', 200, Duration.zero)
        ..countRequest('/x', 'GET', 99, Duration.zero)
        ..countRequest('/x', 'GET', 1000, Duration.zero);
      final samples =
          parse(metrics.render(const MetricsSnapshot(mongoUp: true)))[
              'unpub_http_requests_total']!;
      expect({
        for (final s in samples) '${s.$1['method']} ${s.$1['status']}': s.$2
      }, {
        'DELETE 200': '1',
        'GET $otherStatus': '2'
      });
    });

    test('labels a mounted handler by its prefix', () async {
      shelf.Response ok(shelf.Request request) => shelf.Response.ok('');
      final router = PatternRouter()
        ..get('/top', ok)
        ..mount(
            '/sub/',
            (Router()..get('/x/<id>', (shelf.Request r, String id) => ok(r)))
                .call)
        ..mount('/flat', ok);
      final metrics = Metrics();
      final handler = const shelf.Pipeline()
          .addMiddleware(metrics.middleware(router))
          .addHandler(router.call);
      for (final path in [
        '/sub/x/1',
        '/sub/x/2',
        '/flat',
        '/flat/deep/er',
        '/top',
        '/nothing',
      ]) {
        await handler(shelf.Request('GET', Uri.parse('http://h$path')));
      }
      expect(router.patternOf('POST', '/sub/anything'), '/sub/');
      final samples =
          parse(metrics.render(const MetricsSnapshot(mongoUp: true)))[
              'unpub_http_requests_total']!;
      expect({
        for (final s in samples) s.$1['route']: s.$2
      }, {
        '/sub/': '2',
        '/flat': '2',
        '/top': '1',
        unmatchedRoute: '1',
      });
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

  test('a slow package store does not hold up a scrape', () async {
    final gate = Completer<void>();
    final store = _SlowStore(h.storage.path, gate);
    final app = appWith('', packageStore: store);
    await h.publish('alpha', '1.0.0', bearer: ownerToken, using: app);

    final watch = Stopwatch()..start();
    final scrapes = await Future.wait([
      for (var i = 0; i < 3; i++) scrape(using: app),
    ]);
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    for (final reply in scrapes) {
      expect(reply.status, HttpStatus.ok);
      final samples = parse(reply.body);
      // Nothing measured yet: the gauge is left out, the rest is there.
      expect(samples.containsKey('unpub_storage_bytes'), isFalse);
      expect(samples['unpub_packages']!.single.$2, '1');
    }
    expect(store.measured, 1, reason: 'one measurement at a time');

    gate.complete();
    await app.metricsSources.storage.idle;
    final samples = parse((await scrape(using: app)).body);
    expect(
        int.parse(samples['unpub_storage_bytes']!.single.$2), greaterThan(0));
    expect(samples.containsKey('unpub_storage_measured_timestamp_seconds'),
        isTrue);
    expect(store.measured, 1, reason: 'the value is fresh');
  });

  test('a background value keeps the last measurement', () async {
    var now = DateTime(2026);
    var computed = 0;
    var fail = false;
    final errors = <Object>[];
    final value = BackgroundValue<int>(() async {
      if (fail) throw StateError('down');
      return ++computed;
    },
        maxAge: const Duration(minutes: 10),
        clock: () => now,
        onError: (e, _) => errors.add(e));
    expect(value.current, isNull);
    await value.idle;
    expect(value.current!.value, 1);
    now = now.add(const Duration(minutes: 11));
    // Old: still served while the next measurement runs.
    expect(value.current!.value, 1);
    await value.idle;
    expect(value.current!.value, 2);
    expect(value.current!.at, now);
    now = now.add(const Duration(minutes: 11));
    fail = true;
    expect(value.current!.value, 2);
    await value.idle;
    expect(value.current!.value, 2);
    expect(errors, hasLength(1));
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
