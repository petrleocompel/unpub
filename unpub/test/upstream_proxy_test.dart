import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:mongo_dart/mongo_dart.dart';
import 'package:path/path.dart' as path;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';
import 'package:unpub/unpub.dart';

import 'utils.dart';

const _name = 'remote_pkg';

List<int> _archiveOf(String name, String version) {
  final archive = Archive()
    ..addFile(
        ArchiveFile.string('pubspec.yaml', 'name: $name\nversion: $version\n'))
    ..addFile(ArchiveFile.string('lib/$name.dart', 'void hello() {}\n'));
  return GZipEncoder().encodeBytes(TarEncoder().encodeBytes(archive));
}

/// A small registry speaking the pub API, standing in for pub.dev.
class FakeUpstream {
  late HttpServer _server;
  final requests = <String>[];
  final userAgents = <String?>[];
  final accepts = <String?>[];
  final authorizations = <String?>[];

  /// name → version → archive bytes.
  final packages = <String, Map<String, List<int>>>{};
  final hashOverride = <String, String>{};
  final retracted = <String>{};
  bool discontinued = false;
  String? replacedBy;
  int? failWith;
  bool hang = false;
  bool sendHashes = true;
  String listingVersion = 'a';

  Uri get url => Uri.parse('http://localhost:${_server.port}');

  void add(String name, String version) {
    packages.putIfAbsent(name, () => {})[version] = _archiveOf(name, version);
  }

  String sha(String name, String version) =>
      crypto.sha256.convert(packages[name]![version]!).toString();

  Future<void> start() async {
    _server = await shelf_io.serve(_handle, 'localhost', 0);
  }

  Future<void> stop() => _server.close(force: true);

  int count(String path) => requests.where((r) => r == path).length;

  Future<shelf.Response> _handle(shelf.Request request) async {
    final route = '/${request.url.path}';
    requests.add(route);
    userAgents.add(request.headers['user-agent']);
    accepts.add(request.headers['accept']);
    authorizations.add(request.headers['authorization']);

    if (hang) await Future<void>.delayed(const Duration(seconds: 2));
    if (failWith != null) return shelf.Response(failWith!, body: 'boom');

    final listing = RegExp(r'^/api/packages/(\w+)$').firstMatch(route);
    if (listing != null) return _listing(request, listing.group(1)!);

    final advisories =
        RegExp(r'^/api/packages/(\w+)/advisories$').firstMatch(route);
    if (advisories != null) {
      if (!packages.containsKey(advisories.group(1))) {
        return shelf.Response.notFound('no');
      }
      return shelf.Response.ok(json.encode({
        'advisories': [
          {'id': 'GHSA-1'},
        ],
        'advisoriesUpdated': '2026-01-01T00:00:00.000Z',
      }));
    }

    final archive = RegExp(r'^/storage/(\w+)-(.+)\.tar\.gz$').firstMatch(route);
    if (archive != null) {
      final bytes = packages[archive.group(1)!]?[archive.group(2)!];
      if (bytes == null) return shelf.Response.notFound('no');
      return shelf.Response.ok(bytes);
    }
    return shelf.Response.notFound('no');
  }

  shelf.Response _listing(shelf.Request request, String name) {
    final versions = packages[name];
    if (versions == null) return shelf.Response.notFound('no');

    final etag = '"listing-$name-$listingVersion"';
    if (request.headers['if-none-match'] == etag) {
      return shelf.Response.notModified(headers: {'etag': etag});
    }

    Map<String, Object?> item(String version) => {
          'version': version,
          'pubspec': {
            'name': name,
            'version': version,
            'environment': {'sdk': '^3.5.0'},
            'weird.key': {r'$odd': true},
          },
          'archive_url': '$url/storage/$name-$version.tar.gz',
          if (sendHashes)
            'archive_sha256':
                hashOverride['$name@$version'] ?? sha(name, version),
          'published': '2026-01-02T03:04:05.000Z',
          if (retracted.contains(version)) 'retracted': true,
          'not_a_pub_field': 'dropped',
        };

    return shelf.Response.ok(
      json.encode({
        'name': name,
        'latest': item(versions.keys.last),
        'versions': [for (final v in versions.keys) item(v)],
        'isDiscontinued': discontinued,
        if (replacedBy != null) 'replacedBy': replacedBy,
      }),
      headers: {'etag': etag},
    );
  }
}

void main() {
  late Db db;
  late Directory storage;
  late FakeUpstream upstream;
  late DateTime now;
  late UpstreamProxy proxy;
  late App app;

  const token = 'secret-token';
  const auth = {'authorization': 'Bearer $token'};

  Future<void> clean() async {
    for (final name in [
      packageCollection,
      statsCollection,
      versionStatsCollection,
      upstreamCacheCollection,
      auditCollection,
    ]) {
      await db.dropCollection(name);
    }
  }

  UpstreamProxy buildProxy({
    List<String> allowlist = const [],
    Duration cacheTtl = const Duration(minutes: 10),
    Duration timeout = const Duration(seconds: 5),
    PackageStore? archives,
  }) =>
      UpstreamProxy(
        config: UpstreamConfig(
          url: upstream.url,
          mode: UpstreamMode.proxy,
          cacheTtl: cacheTtl,
          allowlist: allowlist,
          timeout: timeout,
        ),
        cache: MongoUpstreamCacheStore(db),
        archives: archives ?? FileStore(storage.path),
        clock: () => now,
      );

  App buildApp({
    UpstreamProxy? using,
    ReadAccess readAccess = ReadAccess.public,
    PackageStore? packageStore,
  }) =>
      App(
        metaStore: MongoStore(db),
        packageStore: packageStore ?? FileStore(storage.path),
        authenticator: const FakeAuthenticator(token, 'dev@b.c'),
        readAccess: readAccess,
        upstreamProxy: using ?? proxy,
        upstream: upstream.url.toString(),
      );

  Future<shelf.Response> get(String route,
          {Map<String, String> headers = const {}, App? using}) async =>
      (using ?? app).handler(shelf.Request(
        'GET',
        Uri.parse('http://internal:4000$route'),
        headers: headers,
      ));

  Future<Map<String, dynamic>> getJson(String route, {App? using}) async =>
      json.decode(await (await get(route, using: using)).readAsString())
          as Map<String, dynamic>;

  Future<List<int>> bytesOf(shelf.Response response) =>
      response.read().expand((chunk) => chunk).toList();

  File cachedFile(String version) => File(
      path.join(storage.path, 'upstream', _name, '$_name-$version.tar.gz'));

  Future<void> publishLocally(String name, String version, {App? using}) async {
    final response = await (using ?? app)
        .handler(uploadRequest('name: $name\nversion: $version\n', auth));
    return response.headers['location'] == null
        ? fail('no redirect')
        : expect(response.headers['location'], isNot(contains('error=')),
            reason: Uri.decodeFull(response.headers['location'] ?? ''));
  }

  Future<String> publishError(String name, String version) async {
    final response = await app
        .handler(uploadRequest('name: $name\nversion: $version\n', auth));
    final location = Uri.parse(response.headers['location']!);
    return location.queryParameters['error'] ?? '';
  }

  setUpAll(() async {
    db = Db(testMongoUri);
    await db.open();
  });

  tearDownAll(() async {
    await clean();
    await db.close();
  });

  setUp(() async {
    await clean();
    storage = await Directory.systemTemp.createTemp('unpub-proxy-');
    addTearDown(() => storage.delete(recursive: true));
    upstream = FakeUpstream()..add(_name, '1.0.0');
    await upstream.start();
    addTearDown(upstream.stop);
    now = DateTime.now();
    proxy = buildProxy();
    addTearDown(proxy.close);
    app = buildApp();
  });

  test('the cache collection expires entries by a TTL index', () async {
    final store = MongoUpstreamCacheStore(db);
    await store.ensureIndexes();
    await store.ensureIndexes();
    final indexes = await db.collection(upstreamCacheCollection).getIndexes();
    final ttl =
        indexes.singleWhere((index) => index['name'] == 'expires_at_ttl');
    expect(ttl['expireAfterSeconds'], 0);
  });

  group('metadata', () {
    test('rewrites archive urls and keeps the upstream fields', () async {
      upstream.discontinued = true;
      upstream.replacedBy = 'something_else';
      upstream.retracted.add('1.0.0');

      final body = await getJson('/api/packages/$_name');

      expect(body['name'], _name);
      expect(body['isDiscontinued'], isTrue);
      expect(body['replacedBy'], 'something_else');
      final version = (body['versions'] as List).single as Map;
      expect(version['archive_url'],
          'http://internal:4000/packages/$_name/versions/1.0.0.tar.gz');
      expect(version['archive_sha256'], upstream.sha(_name, '1.0.0'));
      expect(version['published'], '2026-01-02T03:04:05.000Z');
      expect(version['retracted'], isTrue);
      expect(version.containsKey('not_a_pub_field'), isFalse);
      expect(body['latest']['archive_url'],
          'http://internal:4000/packages/$_name/versions/1.0.0.tar.gz');
      expect(upstream.userAgents.last, contains('unpub'));
      expect(upstream.accepts.last, 'application/vnd.pub.v2+json');
    });

    test('never forwards the credentials of the client', () async {
      await get('/api/packages/$_name', headers: auth);
      expect(upstream.authorizations, everyElement(isNull));
    });

    test('a second request within the TTL is served from the cache', () async {
      await getJson('/api/packages/$_name');
      await getJson('/api/packages/$_name');
      expect(upstream.count('/api/packages/$_name'), 1);
    });

    test('the cached form holds no absolute url of a client', () async {
      await get('/api/packages/$_name',
          headers: {'host': 'attacker.example.com'});

      final stored = await db
          .collection(upstreamCacheCollection)
          .findOne(where.eq('_id', _name));
      expect(stored!['body'], isNot(contains('attacker')));
      expect(stored['fetchedAt'], isA<DateTime>());
      expect(stored['private'], isFalse);

      final body = await getJson('/api/packages/$_name');
      expect((body['versions'] as List).single['archive_url'],
          startsWith('http://internal:4000/'));
    });

    test('a stale entry is revalidated and a 304 keeps it', () async {
      await getJson('/api/packages/$_name');
      now = now.add(const Duration(minutes: 11));

      final body = await getJson('/api/packages/$_name');

      expect(body['name'], _name);
      expect(upstream.count('/api/packages/$_name'), 2);

      // The confirmation made it fresh again.
      await getJson('/api/packages/$_name');
      expect(upstream.count('/api/packages/$_name'), 2);
    });

    test('a stale entry picks up a change at the upstream', () async {
      await getJson('/api/packages/$_name');
      upstream.add(_name, '2.0.0');
      upstream.listingVersion = 'b';

      expect(
          ((await getJson('/api/packages/$_name'))['versions'] as List).length,
          1);

      now = now.add(const Duration(minutes: 11));
      expect(
          ((await getJson('/api/packages/$_name'))['versions'] as List).length,
          2);
    });

    test('a package removed upstream is forgotten', () async {
      await getJson('/api/packages/$_name');
      upstream.packages.remove(_name);
      now = now.add(const Duration(minutes: 11));

      expect((await get('/api/packages/$_name')).statusCode, 404);
      expect(
          await db
              .collection(upstreamCacheCollection)
              .findOne(where.eq('_id', _name)),
          isNull);
    });

    test('pubspec keys MongoDB would refuse are cached safely', () async {
      await getJson('/api/packages/$_name');
      final cached = await getJson('/api/packages/$_name');
      expect((cached['versions'] as List).single['pubspec']['weird.key'],
          {r'$odd': true});
    });

    test('supports revalidation by clients', () async {
      final first = await get('/api/packages/$_name');
      final etag = first.headers['etag']!;
      expect(first.headers['cache-control'], 'public, max-age=60');

      final second =
          await get('/api/packages/$_name', headers: {'if-none-match': etag});

      expect(second.statusCode, 304);
    });

    test('the version route is proxied the same way', () async {
      final body = await getJson('/api/packages/$_name/versions/1.0.0');
      expect(body['version'], '1.0.0');
      expect(body['archive_url'],
          'http://internal:4000/packages/$_name/versions/1.0.0.tar.gz');
      expect(upstream.count('/api/packages/$_name'), 1);

      expect(
          (await get('/api/packages/$_name/versions/9.9.9')).statusCode, 404);
    });

    test('advisories pass through and are cached', () async {
      final body = await getJson('/api/packages/$_name/advisories');
      expect(body['advisories'], [
        {'id': 'GHSA-1'},
      ]);
      await getJson('/api/packages/$_name/advisories');
      expect(upstream.count('/api/packages/$_name/advisories'), 1);
    });

    test('an unknown package is a 404', () async {
      expect((await get('/api/packages/absent')).statusCode, 404);
      expect((await get('/api/packages/absent/advisories')).statusCode, 404);
      expect(
          (await get('/api/packages/absent/versions/1.0.0')).statusCode, 404);
    });

    test('a local package wins over the upstream', () async {
      await publishLocally('local_pkg', '3.0.0');
      upstream.add('local_pkg', '1.0.0');

      final body = await getJson('/api/packages/local_pkg');

      expect(body['latest']['version'], '3.0.0');
      expect(upstream.count('/api/packages/local_pkg'), 1);
    });
  });

  group('archives', () {
    const route = '/packages/$_name/versions/1.0.0.tar.gz';

    test('the first download fetches, verifies and stores', () async {
      final response = await get(route);

      expect(response.statusCode, 200);
      expect(await bytesOf(response), upstream.packages[_name]!['1.0.0']);
      expect(cachedFile('1.0.0').readAsBytesSync(),
          upstream.packages[_name]!['1.0.0']);
      expect(upstream.count('/storage/$_name-1.0.0.tar.gz'), 1);
    });

    test('later downloads come from the store', () async {
      await bytesOf(await get(route));
      final second = await get(route);
      expect(await bytesOf(second), upstream.packages[_name]!['1.0.0']);
      expect(upstream.count('/storage/$_name-1.0.0.tar.gz'), 1);
    });

    test('concurrent first downloads fetch once', () async {
      final replies = await Future.wait([get(route), get(route), get(route)]);
      for (final reply in replies) {
        expect(await bytesOf(reply), upstream.packages[_name]!['1.0.0']);
      }
      expect(upstream.count('/storage/$_name-1.0.0.tar.gz'), 1);
    });

    test('a corrupt archive is discarded and answered with 502', () async {
      upstream.hashOverride['$_name@1.0.0'] = 'a' * 64;

      final response = await get(route);

      expect(response.statusCode, 502);
      expect(json.decode(await response.readAsString())['error']['message'],
          contains('hash'));
      expect(cachedFile('1.0.0').existsSync(), isFalse);
      expect(
          Directory(path.join(storage.path, 'upstream')).existsSync(), isFalse);
    });

    test('an archive without an upstream hash is still served', () async {
      upstream.sendHashes = false;
      final response = await get(route);
      expect(response.statusCode, 200);
      expect(await bytesOf(response), upstream.packages[_name]!['1.0.0']);
      expect(cachedFile('1.0.0').existsSync(), isTrue);
    });

    test('has a strong validator and honours it', () async {
      final hash = upstream.sha(_name, '1.0.0');
      final first = await get(route);
      expect(first.headers['etag'], '"$hash"');
      expect(first.headers['cache-control'],
          'public, max-age=31536000, immutable');
      await bytesOf(first);

      final second = await get(route, headers: {'if-none-match': '"$hash"'});
      expect(second.statusCode, 304);
    });

    test('a version the upstream does not have is a 404', () async {
      expect((await get('/packages/$_name/versions/9.9.9.tar.gz')).statusCode,
          404);
    });

    test('is not counted, because a proxied package has no record', () async {
      await bytesOf(
          await get(route, headers: {'user-agent': 'Dart pub 3.12.0'}));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await db.collection(versionStatsCollection).findOne(), isNull);
      expect(await db.collection(statsCollection).findOne(), isNull);
    });

    test('a cached archive is stored apart from published ones', () async {
      await bytesOf(await get(route));
      expect(await FileStore(storage.path).exists(_name, '1.0.0'), isFalse);
      expect(
          await FileStore(storage.path).upstreamCached(_name, '1.0.0'), isTrue);
    });
  });

  group('allowlist', () {
    setUp(() {
      proxy = buildProxy(allowlist: ['only_this']);
      addTearDown(proxy.close);
      app = buildApp();
    });

    for (final route in [
      '/api/packages/$_name',
      '/api/packages/$_name/versions/1.0.0',
      '/api/packages/$_name/advisories',
      '/packages/$_name/versions/1.0.0.tar.gz',
    ]) {
      test('$route is denied without asking the upstream', () async {
        expect((await get(route)).statusCode, 404);
        expect(upstream.requests, isEmpty);
      });
    }

    test('a listed package is proxied', () async {
      upstream.add('only_this', '1.0.0');
      expect((await get('/api/packages/only_this')).statusCode, 200);
    });

    test('a package off the list can be published here', () async {
      await publishLocally(_name, '1.0.0');
      expect(upstream.requests, isEmpty);
    });
  });

  group('publishing', () {
    test('refuses a name cached from the upstream', () async {
      await get('/api/packages/$_name');
      upstream.requests.clear();
      upstream.failWith = 500;

      expect(await publishError(_name, '1.0.0'),
          contains('exists on the upstream registry'));
      expect(upstream.requests, isEmpty);
      expect(
          await db
              .collection(packageCollection)
              .findOne(where.eq('name', _name)),
          isNull);
    });

    test('refuses a name that only exists upstream', () async {
      expect(await publishError(_name, '1.0.0'),
          contains('exists on the upstream registry'));
      expect(upstream.count('/api/packages/$_name'), 1);
    });

    test('accepts a name the upstream does not have', () async {
      await publishLocally('brand_new', '1.0.0');
      expect(
          await db
              .collection(packageCollection)
              .findOne(where.eq('name', 'brand_new')),
          isNotNull);
    });

    test('allows the publish with a warning if the upstream fails', () async {
      upstream.failWith = 500;
      await publishLocally('brand_new', '1.0.0');
      expect(
          await db
              .collection(packageCollection)
              .findOne(where.eq('name', 'brand_new')),
          isNotNull);
    });

    test('a new version of a local package does not ask the upstream',
        () async {
      await publishLocally('brand_new', '1.0.0');
      upstream.requests.clear();
      await publishLocally('brand_new', '1.1.0');
      expect(upstream.requests, isEmpty);
    });

    test('redirect mode keeps its behaviour', () async {
      final redirect = App(
        metaStore: MongoStore(db),
        packageStore: FileStore(storage.path),
        authenticator: const FakeAuthenticator(token, 'dev@b.c'),
        upstream: upstream.url.toString(),
      );
      await publishLocally(_name, '1.0.0', using: redirect);
      expect(upstream.requests, isEmpty);

      final other = await redirect.handler(shelf.Request(
          'GET', Uri.parse('http://internal:4000/api/packages/elsewhere')));
      expect(other.statusCode, HttpStatus.found);
      expect(
          other.headers['location'], '${upstream.url}/api/packages/elsewhere');
    });
  });

  group('upstream failures', () {
    const route = '/packages/$_name/versions/1.0.0.tar.gz';

    for (final status in [500, 503, 429, 403]) {
      test('$status for metadata is a JSON 502', () async {
        upstream.failWith = status;
        final response = await get('/api/packages/$_name');
        expect(response.statusCode, 502);
        final body = json.decode(await response.readAsString());
        expect(body['error']['message'], isA<String>());
      });
    }

    test('an unreachable upstream is a JSON 502', () async {
      await upstream.stop();
      final response = await get('/api/packages/$_name');
      expect(response.statusCode, 502);
      expect(json.decode(await response.readAsString())['error'], isNotNull);
    });

    test('a slow upstream times out into a 502', () async {
      upstream.hang = true;
      final slow = buildProxy(timeout: const Duration(milliseconds: 100));
      addTearDown(slow.close);
      final response =
          await get('/api/packages/$_name', using: buildApp(using: slow));
      expect(response.statusCode, 502);
    });

    for (final body in [
      'not json',
      '[1]',
      '{"name": "other", "versions": []}'
    ]) {
      test('the listing "$body" is a 502', () async {
        final fake = await shelf_io.serve(
            (_) => shelf.Response.ok(body), 'localhost', 0);
        addTearDown(() => fake.close(force: true));
        final broken = UpstreamProxy(
          config: UpstreamConfig(
              url: Uri.parse('http://localhost:${fake.port}'),
              mode: UpstreamMode.proxy),
          cache: MongoUpstreamCacheStore(db),
          archives: FileStore(storage.path),
        );
        addTearDown(broken.close);
        final response =
            await get('/api/packages/$_name', using: buildApp(using: broken));
        expect(response.statusCode, 502);
      });
    }

    test('metadata within the TTL needs no upstream', () async {
      await getJson('/api/packages/$_name');
      upstream.failWith = 500;
      expect((await get('/api/packages/$_name')).statusCode, 200);
    });

    test('stale metadata with a failing upstream is a 502', () async {
      await getJson('/api/packages/$_name');
      upstream.failWith = 500;
      now = now.add(const Duration(minutes: 11));
      expect((await get('/api/packages/$_name')).statusCode, 502);
    });

    test('a cached archive is served while the upstream is down', () async {
      await bytesOf(await get(route));
      await upstream.stop();
      now = now.add(const Duration(minutes: 11));

      final response = await get(route);

      expect(response.statusCode, 200);
      expect(await bytesOf(response), upstream.packages[_name]!['1.0.0']);
    });

    test('an archive that is not cached is a 502 when it is down', () async {
      await getJson('/api/packages/$_name');
      upstream.failWith = 500;
      expect((await get(route)).statusCode, 502);
    });
  });

  group('authenticated mode', () {
    const route = '/packages/$_name/versions/1.0.0.tar.gz';

    setUp(() {
      app = buildApp(readAccess: ReadAccess.authenticated);
    });

    test('a proxied download needs a token', () async {
      expect((await get(route)).statusCode, 401);
      expect((await get('/api/packages/$_name')).statusCode, 401);
      expect(upstream.requests, isEmpty);
    });

    test('with a token it works and is marked private', () async {
      final response = await get(route, headers: auth);
      expect(response.statusCode, 200);
      expect(response.headers['cache-control'], 'private');
      await bytesOf(response);

      final listing = await get('/api/packages/$_name', headers: auth);
      expect(listing.headers['cache-control'], 'private, no-store');
    });
  });

  group('dart pub', () {
    late HttpServer server;

    setUpAll(setUpPubClient);
    tearDownAll(tearDownPubClient);

    tearDown(() => server.close());

    test('resolves and downloads a proxied package', () async {
      server = await app.serve('0.0.0.0', 4000);
      final consumer = await createConsumer(_name, '1.0.0');

      final result = await pubGet(consumer);

      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(lockedVersion(consumer, _name), '1.0.0');
      expect(cachedFile('1.0.0').existsSync(), isTrue);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
