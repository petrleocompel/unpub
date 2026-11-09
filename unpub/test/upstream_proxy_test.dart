import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
  final validators = <String?>[];

  /// name → version → archive bytes.
  final packages = <String, Map<String, List<int>>>{};
  final hashOverride = <String, String>{};
  final retracted = <String>{};

  /// Replaces the `archive_url` of the listing, by package name.
  String Function(String name, String version)? archiveUrlOf;

  /// When set, each archive arrives in pieces this far apart.
  Duration? trickle;

  /// How long each archive request takes to be answered.
  Duration? archiveDelay;
  int _activeArchives = 0;
  int peakArchives = 0;

  /// Route → the `Location` it redirects to.
  final redirects = <String, String>{};
  bool discontinued = false;
  String? replacedBy;
  int? failWith;
  bool hang = false;
  bool sendHashes = true;

  /// Answers every listing with a 304, asked for or not.
  bool alwaysNotModified = false;
  String listingVersion = 'a';

  /// Kept from [start], since a late request can outlive the server.
  late final Uri url;

  void add(String name, String version) {
    packages.putIfAbsent(name, () => {})[version] = _archiveOf(name, version);
  }

  String sha(String name, String version) =>
      crypto.sha256.convert(packages[name]![version]!).toString();

  Future<void> start() async {
    _server = await shelf_io.serve(_handle, 'localhost', 0);
    url = Uri.parse('http://localhost:${_server.port}');
  }

  Future<void> stop() => _server.close(force: true);

  int count(String path) => requests.where((r) => r == path).length;

  Future<shelf.Response> _handle(shelf.Request request) async {
    final route = '/${request.url.path}';
    requests.add(route);
    userAgents.add(request.headers['user-agent']);
    accepts.add(request.headers['accept']);
    authorizations.add(request.headers['authorization']);
    validators.add(request.headers['if-none-match']);

    if (hang) await Future<void>.delayed(const Duration(seconds: 2));
    final redirect = redirects[route];
    if (redirect != null) {
      return shelf.Response.found(redirect);
    }
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
      peakArchives = max(peakArchives, ++_activeArchives);
      try {
        if (archiveDelay != null) await Future<void>.delayed(archiveDelay!);
      } finally {
        _activeArchives--;
      }
      final pause = trickle;
      if (pause == null) return shelf.Response.ok(bytes);
      return shelf.Response.ok(_trickled(bytes, pause),
          context: const {'shelf.io.buffer_output': false});
    }
    return shelf.Response.notFound('no');
  }

  static Stream<List<int>> _trickled(List<int> bytes, Duration pause) async* {
    final step = (bytes.length / 15).ceil();
    for (var start = 0; start < bytes.length; start += step) {
      if (start > 0) await Future<void>.delayed(pause);
      yield bytes.sublist(start, min(start + step, bytes.length));
    }
  }

  shelf.Response _listing(shelf.Request request, String name) {
    if (alwaysNotModified) return shelf.Response.notModified();
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
          'archive_url': archiveUrlOf?.call(name, version) ??
              '$url/storage/$name-$version.tar.gz',
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

/// Keeps nothing, as a custom store with the defaults does.
class _NothingKeptStore extends PackageStore {
  final temporary = <File>[];

  @override
  Future<void> upload(String name, String version, List<int> content) async {}

  @override
  Future<File> upstreamTemporaryFile(String name, String version) async {
    final file = await super.upstreamTemporaryFile(name, version);
    temporary.add(file);
    return file;
  }
}

class _FailingCommitStore extends FileStore {
  _FailingCommitStore(super.baseDir);

  @override
  Future<bool> commitUpstream(String name, String version, String digest,
          File temporary, int size) =>
      throw const FileSystemException('disk full');
}

/// Stops before writing an archive record, as a stalled instance would.
class _PausingRecords implements UpstreamCacheStore {
  final UpstreamCacheStore inner;
  final reached = Completer<void>();
  final resume = Completer<void>();

  _PausingRecords(this.inner);

  @override
  Future<UpstreamCacheEntry?> read(String key) => inner.read(key);

  @override
  Future<void> write(UpstreamCacheEntry entry, DateTime expiresAt) =>
      inner.write(entry, expiresAt);

  @override
  Future<void> touch(String key, DateTime fetchedAt, DateTime expiresAt) =>
      inner.touch(key, fetchedAt, expiresAt);

  @override
  Future<void> delete(String key) => inner.delete(key);

  @override
  Future<UpstreamArchiveRecord?> readArchive(String name, String version) =>
      inner.readArchive(name, version);

  @override
  Future<void> writeArchive(UpstreamArchiveRecord record) async {
    if (!reached.isCompleted) reached.complete();
    await resume.future;
    await inner.writeArchive(record);
  }

  @override
  Future<void> deleteArchive(String name, String version) =>
      inner.deleteArchive(name, version);
}

/// Accepts everything but recording an archive.
class _FailingRecords extends _PausingRecords {
  _FailingRecords(super.inner);

  @override
  Future<void> writeArchive(UpstreamArchiveRecord record) =>
      throw StateError('record write failed');
}

String sha256Of(List<int> bytes) => crypto.sha256.convert(bytes).toString();

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
      upstreamArchivesCollection,
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
    List<String> allowedArchiveHosts = const [],
    bool requireSha256 = true,
    int maxArchiveBytes = UpstreamConfig.defaultMaxArchiveBytes,
    int maxConcurrentFetches = UpstreamConfig.defaultMaxConcurrentFetches,
    UpstreamCacheStore? cache,
  }) =>
      UpstreamProxy(
        config: UpstreamConfig(
          url: upstream.url,
          mode: UpstreamMode.proxy,
          cacheTtl: cacheTtl,
          allowlist: allowlist,
          timeout: timeout,
          allowedArchiveHosts: allowedArchiveHosts,
          requireSha256: requireSha256,
          maxArchiveBytes: maxArchiveBytes,
          maxConcurrentFetches: maxConcurrentFetches,
        ),
        cache: cache ?? MongoUpstreamCacheStore(db),
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

  File objectFile(String version, String digest) => File(path.join(
      storage.path, 'upstream', _name, '$_name-$version-$digest.tar.gz'));

  /// Where the bytes the fake upstream holds for [version] are kept.
  File cachedFile(String version) =>
      objectFile(version, sha256Of(upstream.packages[_name]![version]!));

  /// The bytes of [response] must be the ones its `ETag` names.
  Future<String> expectMatchesValidator(shelf.Response response) async {
    expect(response.statusCode, 200);
    final digest = RegExp(r'^(?:W/)?"([0-9a-f]{64})"$')
        .firstMatch(response.headers['etag']!)!
        .group(1)!;
    expect(sha256Of(await bytesOf(response)), digest);
    return digest;
  }

  List<String> filesInStorage() => [
        for (final entity in storage.listSync(recursive: true))
          if (entity is File) entity.path,
      ];

  Future<void> publishLocally(String name, String version, {App? using}) async {
    final response = await (using ?? app)
        .handler(uploadRequest('name: $name\nversion: $version\n', auth));
    return response.headers['location'] == null
        ? fail('no redirect')
        : expect(response.headers['location'], isNot(contains('error=')),
            reason: Uri.decodeFull(response.headers['location'] ?? ''));
  }

  Future<String> publishError(String name, String version, {App? using}) async {
    final response = await (using ?? app)
        .handler(uploadRequest('name: $name\nversion: $version\n', auth));
    final location = Uri.parse(response.headers['location']!);
    return location.queryParameters['error'] ?? '';
  }

  /// What `dart pub publish` is told when it follows the upload's redirect.
  Future<shelf.Response> publishOutcome(String name, String version,
      {App? using}) async {
    final response = await (using ?? app)
        .handler(uploadRequest('name: $name\nversion: $version\n', auth));
    final location = Uri.parse(response.headers['location']!);
    return get(location.toString().substring('http://internal:4000'.length),
        headers: auth, using: using);
  }

  Future<Map<String, dynamic>?> localPackage(String name) =>
      db.collection(packageCollection).findOne(where.eq('name', name));

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
      expect(filesInStorage(), isEmpty);
    });

    group('the upstream hash', () {
      App lenient() {
        final relaxed = buildProxy(requireSha256: false);
        addTearDown(relaxed.close);
        return buildApp(using: relaxed);
      }

      test('in uppercase is verified, not skipped', () async {
        upstream.hashOverride['$_name@1.0.0'] =
            upstream.sha(_name, '1.0.0').toUpperCase();

        final response = await get(route);

        expect(response.statusCode, 200);
        expect(response.headers['etag'], '"${upstream.sha(_name, '1.0.0')}"');
        expect(await bytesOf(response), upstream.packages[_name]!['1.0.0']);
      });

      test('in uppercase is listed in lowercase', () async {
        upstream.hashOverride['$_name@1.0.0'] =
            upstream.sha(_name, '1.0.0').toUpperCase();
        final body = await getJson('/api/packages/$_name');
        expect((body['versions'] as List).single['archive_sha256'],
            upstream.sha(_name, '1.0.0'));
      });

      test('in uppercase that does not match is refused', () async {
        upstream.hashOverride['$_name@1.0.0'] = 'A' * 64;
        final response = await get(route);
        expect(response.statusCode, 502);
        expect(cachedFile('1.0.0').existsSync(), isFalse);
      });

      for (final malformed in [
        'not-a-hash',
        'a' * 63,
        'a' * 65,
        'g' * 64,
        ''
      ]) {
        test('malformed as "$malformed" is a 502', () async {
          upstream.hashOverride['$_name@1.0.0'] = malformed;

          final response = await get(route);

          expect(response.statusCode, 502);
          expect(json.decode(await response.readAsString())['error']['message'],
              'upstream provided an invalid archive_sha256');
          expect(upstream.count('/storage/$_name-1.0.0.tar.gz'), 0);
          expect(cachedFile('1.0.0').existsSync(), isFalse);
        });
      }

      test('malformed is also a 502 with requireSha256 off', () async {
        upstream.hashOverride['$_name@1.0.0'] = 'not-a-hash';
        expect((await get(route, using: lenient())).statusCode, 502);
      });

      test('malformed leaves the listing usable, without the hash', () async {
        upstream.hashOverride['$_name@1.0.0'] = 'not-a-hash';
        final body = await getJson('/api/packages/$_name');
        expect((body['versions'] as List).single.containsKey('archive_sha256'),
            isFalse);
      });

      test('malformed stays a 502 from the cached listing', () async {
        upstream.hashOverride['$_name@1.0.0'] = 'not-a-hash';
        await getJson('/api/packages/$_name');
        upstream.requests.clear();

        expect((await get(route)).statusCode, 502);
        expect(upstream.count('/api/packages/$_name'), 0);
      });

      test('absent is a 502 by default', () async {
        upstream.sendHashes = false;

        final response = await get(route);

        expect(response.statusCode, 502);
        expect(json.decode(await response.readAsString())['error']['message'],
            'upstream provides no archive_sha256 for $_name 1.0.0');
        expect(upstream.count('/storage/$_name-1.0.0.tar.gz'), 0);
        expect(cachedFile('1.0.0').existsSync(), isFalse);
      });

      test('absent is served unverified with requireSha256 off', () async {
        upstream.sendHashes = false;

        final response = await get(route, using: lenient());

        expect(response.statusCode, 200);
        expect(response.headers['etag'], 'W/"${upstream.sha(_name, '1.0.0')}"');
        expect(await bytesOf(response), upstream.packages[_name]!['1.0.0']);
        expect(cachedFile('1.0.0').existsSync(), isTrue);
      });
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

    group('through a temporary file', () {
      test('the size cap aborts and leaves no file', () async {
        final capped = buildProxy(maxArchiveBytes: 10);
        addTearDown(capped.close);

        final response = await get(route, using: buildApp(using: capped));

        expect(response.statusCode, 502);
        expect(json.decode(await response.readAsString())['error']['message'],
            contains('maxArchiveBytes'));
        expect(filesInStorage(), isEmpty);
        expect(await MongoUpstreamCacheStore(db).readArchive(_name, '1.0.0'),
            isNull);
      });

      test('the size cap holds without a declared length', () async {
        upstream.trickle = const Duration(milliseconds: 20);
        final capped = buildProxy(maxArchiveBytes: 10);
        addTearDown(capped.close);

        final response = await get(route, using: buildApp(using: capped));

        expect(response.statusCode, 502);
        expect(filesInStorage(), isEmpty);
      });

      test('a declared length over the cap is refused at once', () async {
        final declaring = await HttpServer.bind('localhost', 0);
        addTearDown(() => declaring.close(force: true));
        declaring.listen((request) async {
          if (request.uri.path.startsWith('/api/')) {
            request.response
              ..headers.contentType = ContentType.json
              ..write(json.encode({
                'name': _name,
                'versions': [
                  {
                    'version': '1.0.0',
                    'pubspec': {'name': _name, 'version': '1.0.0'},
                    'archive_url':
                        'http://localhost:${declaring.port}/a.tar.gz',
                    'archive_sha256': 'a' * 64,
                  },
                ],
              }));
            await request.response.close();
            return;
          }
          // Declares a body, then never sends it.
          request.response.contentLength = 1000;
          await request.response.detachSocket(writeHeaders: true);
        });
        final capped = UpstreamProxy(
          config: UpstreamConfig(
            url: Uri.parse('http://localhost:${declaring.port}'),
            mode: UpstreamMode.proxy,
            maxArchiveBytes: 100,
            timeout: const Duration(seconds: 20),
          ),
          cache: MongoUpstreamCacheStore(db),
          archives: FileStore(storage.path),
        );
        addTearDown(capped.close);

        final watch = Stopwatch()..start();
        final response = await get(route, using: buildApp(using: capped));

        expect(response.statusCode, 502);
        expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
        expect(filesInStorage(), isEmpty);
      });

      test('an archive exactly at the size cap passes', () async {
        final capped = buildProxy(
            maxArchiveBytes: upstream.packages[_name]!['1.0.0']!.length);
        addTearDown(capped.close);
        final response = await get(route, using: buildApp(using: capped));
        expect(response.statusCode, 200);
        await bytesOf(response);
      });

      test('a failure to verify leaves no file', () async {
        upstream.hashOverride['$_name@1.0.0'] = 'a' * 64;
        expect((await get(route)).statusCode, 502);
        expect(filesInStorage(), isEmpty);
      });

      test('a connection lost mid-body leaves no file', () async {
        final broken = await HttpServer.bind('localhost', 0);
        addTearDown(() => broken.close(force: true));
        broken.listen((request) async {
          if (request.uri.path.startsWith('/api/')) {
            request.response
              ..headers.contentType = ContentType.json
              ..write(json.encode({
                'name': _name,
                'versions': [
                  {
                    'version': '1.0.0',
                    'pubspec': {'name': _name, 'version': '1.0.0'},
                    'archive_url': 'http://localhost:${broken.port}/a.tar.gz',
                    'archive_sha256': 'a' * 64,
                  },
                ],
              }));
            await request.response.close();
            return;
          }
          request.response.contentLength = 1000;
          final socket =
              await request.response.detachSocket(writeHeaders: true);
          socket.write('partial');
          await socket.flush();
          socket.destroy();
        });
        final flaky = UpstreamProxy(
          config: UpstreamConfig(
              url: Uri.parse('http://localhost:${broken.port}'),
              mode: UpstreamMode.proxy),
          cache: MongoUpstreamCacheStore(db),
          archives: FileStore(storage.path),
        );
        addTearDown(flaky.close);

        final response = await get(route, using: buildApp(using: flaky));

        expect(response.statusCode, 502);
        expect(filesInStorage(), isEmpty);
      });

      test('a store that caches nothing still gets the archive served',
          () async {
        final store = _NothingKeptStore();
        final uncached = buildProxy(archives: store);

        final replies = await Future.wait([
          get(route, using: buildApp(using: uncached, packageStore: store)),
          get(route, using: buildApp(using: uncached, packageStore: store)),
        ]);

        for (final reply in replies) {
          expect(await bytesOf(reply), upstream.packages[_name]!['1.0.0']);
        }
        expect(upstream.count('/storage/$_name-1.0.0.tar.gz'), 1);
        expect(store.temporary.single.existsSync(), isTrue);

        uncached.close();
        expect(store.temporary.single.existsSync(), isFalse);
      });

      test('a store that fails does not fail the download', () async {
        final store = _FailingCommitStore(storage.path);
        final failing = buildProxy(archives: store);
        addTearDown(failing.close);

        final response = await get(route,
            using: buildApp(using: failing, packageStore: store));

        expect(await bytesOf(response), upstream.packages[_name]!['1.0.0']);
        expect(cachedFile('1.0.0').existsSync(), isFalse);
      });
    });

    group('maxConcurrentFetches', () {
      for (final version in ['1.0.1', '1.0.2', '1.0.3', '1.0.4']) {
        setUp(() => upstream.add(_name, version));
      }

      test('bounds how many archives are fetched at once', () async {
        upstream.archiveDelay = const Duration(milliseconds: 200);
        final limited = buildProxy(maxConcurrentFetches: 2);
        addTearDown(limited.close);
        final limitedApp = buildApp(using: limited);

        final replies = await Future.wait([
          for (final version in ['1.0.0', '1.0.1', '1.0.2', '1.0.3', '1.0.4'])
            get('/packages/$_name/versions/$version.tar.gz', using: limitedApp),
        ]);

        for (final reply in replies) {
          expect(reply.statusCode, 200);
          await bytesOf(reply);
        }
        expect(upstream.peakArchives, 2);
      });

      test('a download that waits too long is a 503', () async {
        upstream.trickle = const Duration(milliseconds: 200);
        final limited = buildProxy(
            maxConcurrentFetches: 1, timeout: const Duration(seconds: 1));
        addTearDown(limited.close);
        final limitedApp = buildApp(using: limited);

        final running = get(route, using: limitedApp);
        while (upstream.count('/storage/$_name-1.0.0.tar.gz') == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        final refused = await get('/packages/$_name/versions/1.0.1.tar.gz',
            using: limitedApp);

        expect(refused.statusCode, 503);
        expect(json.decode(await refused.readAsString())['error']['message'],
            contains('try again'));
        final first = await running;
        expect(first.statusCode, 200);
        await bytesOf(first);
      });
    });

    group('a kept archive', () {
      Future<void> refreshListing() async {
        upstream.listingVersion = 'b';
        now = now.add(const Duration(minutes: 11));
        await getJson('/api/packages/$_name');
      }

      test('records its digest and size', () async {
        await bytesOf(await get(route));

        final record =
            await MongoUpstreamCacheStore(db).readArchive(_name, '1.0.0');
        expect(record!.sha256, upstream.sha(_name, '1.0.0'));
        expect(record.bytes, upstream.packages[_name]!['1.0.0']!.length);
        expect(record.verified, isTrue);
      });

      test('uses the stored digest once the listing has expired', () async {
        await bytesOf(await get(route));
        await MongoUpstreamCacheStore(db).delete(_name);
        await upstream.stop();

        final response = await get(route);

        expect(response.statusCode, 200);
        expect(response.headers['etag'], '"${upstream.sha(_name, '1.0.0')}"');
        await bytesOf(response);
      });

      test('is replaced when the listing changes its hash', () async {
        await bytesOf(await get(route));
        final original = upstream.packages[_name]!['1.0.0']!;
        upstream.packages[_name]!['1.0.0'] = _archiveOf(_name, '1.0.0+other');
        final replacement = upstream.sha(_name, '1.0.0');
        expect(sha256Of(original), isNot(replacement));
        await refreshListing();

        final response = await get(route);

        expect(response.statusCode, 200);
        expect(response.headers['etag'], '"$replacement"');
        expect(await bytesOf(response), upstream.packages[_name]!['1.0.0']);
        expect(sha256Of(cachedFile('1.0.0').readAsBytesSync()), replacement);
        expect(
            (await MongoUpstreamCacheStore(db).readArchive(_name, '1.0.0'))!
                .sha256,
            replacement);
      });

      test('never goes out under the new hash when the refetch fails to verify',
          () async {
        await bytesOf(await get(route));
        upstream.hashOverride['$_name@1.0.0'] = 'b' * 64;
        await refreshListing();

        final response = await get(route);

        expect(response.statusCode, 502);
        expect(cachedFile('1.0.0').existsSync(), isFalse);
        expect(await MongoUpstreamCacheStore(db).readArchive(_name, '1.0.0'),
            isNull);
      });

      test('is a 502 when the hash changed and the upstream is down', () async {
        await bytesOf(await get(route));
        upstream.hashOverride['$_name@1.0.0'] = 'b' * 64;
        await refreshListing();
        upstream.failWith = 500;

        expect((await get(route)).statusCode, 502);
      });

      test('the validator of the old bytes stops matching', () async {
        final digest = upstream.sha(_name, '1.0.0');
        await bytesOf(await get(route));
        upstream.packages[_name]!['1.0.0'] = _archiveOf(_name, '1.0.0+other');
        await refreshListing();

        final response =
            await get(route, headers: {'if-none-match': '"$digest"'});

        expect(response.statusCode, 200);
        await bytesOf(response);
      });

      test('without a recorded digest is fetched again', () async {
        await bytesOf(await get(route));
        await MongoUpstreamCacheStore(db).deleteArchive(_name, '1.0.0');
        upstream.requests.clear();

        final response = await get(route);

        expect(await bytesOf(response), upstream.packages[_name]!['1.0.0']);
        expect(upstream.count('/storage/$_name-1.0.0.tar.gz'), 1);
        expect(await MongoUpstreamCacheStore(db).readArchive(_name, '1.0.0'),
            isNotNull);
      });

      test('that was not verified gets a weak validator', () async {
        upstream.sendHashes = false;
        final relaxed = buildProxy(requireSha256: false);
        addTearDown(relaxed.close);
        final lenient = buildApp(using: relaxed);
        await bytesOf(await get(route, using: lenient));

        final second = await get(route, using: lenient);

        expect(second.statusCode, 200);
        expect(second.headers['etag'], 'W/"${upstream.sha(_name, '1.0.0')}"');
        expect(upstream.count('/storage/$_name-1.0.0.tar.gz'), 1);
        await bytesOf(second);
      });

      test('that was not verified honours its weak validator', () async {
        upstream.sendHashes = false;
        final relaxed = buildProxy(requireSha256: false);
        addTearDown(relaxed.close);
        final lenient = buildApp(using: relaxed);
        final etag = (await get(route, using: lenient)).headers['etag']!;

        final second =
            await get(route, using: lenient, headers: {'if-none-match': etag});

        expect(second.statusCode, 304);
        expect(second.headers['etag'], etag);
      });

      test('whose object is gone counts as not cached', () async {
        await bytesOf(await get(route));
        await cachedFile('1.0.0').delete();
        upstream.requests.clear();

        final response = await get(route);

        expect(await bytesOf(response), upstream.packages[_name]!['1.0.0']);
        expect(upstream.count('/storage/$_name-1.0.0.tar.gz'), 1);
        expect(cachedFile('1.0.0').existsSync(), isTrue);
      });

      test('a file at the mutable path of earlier commits is ignored',
          () async {
        final legacy = File(
            path.join(storage.path, 'upstream', _name, '$_name-1.0.0.tar.gz'))
          ..createSync(recursive: true)
          ..writeAsStringSync('stale bytes of an earlier development build');

        final response = await get(route);

        expect(await bytesOf(response), upstream.packages[_name]!['1.0.0']);
        expect(legacy.existsSync(), isTrue);
        expect(upstream.count('/storage/$_name-1.0.0.tar.gz'), 1);
      });

      test('a failed record write never serves new bytes as the old ones',
          () async {
        final digestA = upstream.sha(_name, '1.0.0');
        await bytesOf(await get(route));
        await cachedFile('1.0.0').delete();

        // The upstream now offers other bytes, and no hash to check them by.
        upstream.packages[_name]!['1.0.0'] = _archiveOf(_name, '1.0.0+other');
        final digestB = upstream.sha(_name, '1.0.0');
        upstream.sendHashes = false;
        upstream.listingVersion = 'b';
        now = now.add(const Duration(minutes: 11));
        final failing = buildProxy(
            requireSha256: false,
            cache: _FailingRecords(MongoUpstreamCacheStore(db)));
        addTearDown(failing.close);
        final lenient = buildApp(using: failing);
        upstream.requests.clear();

        for (final attempt in [1, 2]) {
          final response = await get(route, using: lenient);
          expect(response.statusCode, 200);
          expect(response.headers['etag'], 'W/"$digestB"');
          expect(await expectMatchesValidator(response), digestB);
          expect(upstream.count('/storage/$_name-1.0.0.tar.gz'), attempt,
              reason: 'nothing usable is recorded, so it is fetched again');
        }

        final record =
            await MongoUpstreamCacheStore(db).readArchive(_name, '1.0.0');
        expect(record!.sha256, digestA);
        expect(objectFile('1.0.0', digestA).existsSync(), isFalse);
        final revalidated = await get(route,
            using: lenient, headers: {'if-none-match': '"$digestA"'});
        expect(revalidated.statusCode, 200,
            reason: 'the record names an object that is gone');
        expect(revalidated.headers['etag'], 'W/"$digestB"');
        await bytesOf(revalidated);
      });

      group('shared by two instances that interleave', () {
        late _PausingRecords stalled;
        late App instanceA;
        late App instanceB;

        void startInstances({required bool requireSha256}) {
          stalled = _PausingRecords(MongoUpstreamCacheStore(db));
          final proxyA =
              buildProxy(cache: stalled, requireSha256: requireSha256);
          final proxyB = buildProxy(requireSha256: requireSha256);
          addTearDown(proxyA.close);
          addTearDown(proxyB.close);
          instanceA = buildApp(using: proxyA);
          instanceB = buildApp(using: proxyB);
        }

        /// A commits its bytes and stalls before recording them, while B
        /// commits and records other bytes, and then A records its own.
        Future<(String, String)> interleave() async {
          final running = get(route, using: instanceA);
          await stalled.reached.future;
          final digestA = upstream.sha(_name, '1.0.0');

          upstream.packages[_name]!['1.0.0'] = _archiveOf(_name, '1.0.0+other');
          await MongoUpstreamCacheStore(db).delete(_name);
          final digestB =
              await expectMatchesValidator(await get(route, using: instanceB));
          expect(digestB, upstream.sha(_name, '1.0.0'));
          expect(digestB, isNot(digestA));

          stalled.resume.complete();
          expect(await expectMatchesValidator(await running), digestA);
          return (digestA, digestB);
        }

        test('with hashes, every response matches its validator', () async {
          startInstances(requireSha256: true);
          final (digestA, digestB) = await interleave();

          // A recorded last, but the listing asks for B, so B is fetched
          // again rather than A served under either name.
          for (final instance in [instanceA, instanceB, instanceA]) {
            expect(
                await expectMatchesValidator(await get(route, using: instance)),
                digestB);
          }
          expect(
              (await MongoUpstreamCacheStore(db).readArchive(_name, '1.0.0'))!
                  .sha256,
              digestB);
          expect(objectFile('1.0.0', digestA).existsSync(), isFalse,
              reason: 'the listing rules it out, so it is forgotten');
        });

        test('without hashes, the last record wins with its own bytes',
            () async {
          upstream.sendHashes = false;
          startInstances(requireSha256: false);
          final (digestA, digestB) = await interleave();

          for (final instance in [instanceA, instanceB]) {
            final response = await get(route, using: instance);
            expect(response.headers['etag'], startsWith('W/'));
            expect(await expectMatchesValidator(response), digestA);
          }
          expect(objectFile('1.0.0', digestA).existsSync(), isTrue);
          expect(objectFile('1.0.0', digestB).existsSync(), isTrue);
        });
      });

      test('that was not verified is refused once a hash is required',
          () async {
        upstream.sendHashes = false;
        final relaxed = buildProxy(requireSha256: false);
        addTearDown(relaxed.close);
        await bytesOf(await get(route, using: buildApp(using: relaxed)));

        expect((await get(route)).statusCode, 502);
      });
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
          await FileStore(storage.path)
              .upstreamCached(_name, '1.0.0', upstream.sha(_name, '1.0.0')),
          isTrue);
    });
  });

  group('archive locations', () {
    const route = '/packages/$_name/versions/1.0.0.tar.gz';
    late HttpServer elsewhere;
    late List<String> elsewhereRequests;

    /// A server with another host and port than [upstream], holding the
    /// archive.
    setUp(() async {
      elsewhereRequests = [];
      elsewhere = await shelf_io.serve((shelf.Request request) {
        elsewhereRequests.add('/${request.url.path}');
        return shelf.Response.ok(upstream.packages[_name]!['1.0.0']);
      }, InternetAddress.loopbackIPv4, 0);
      addTearDown(() => elsewhere.close(force: true));
    });

    String elsewhereUrl([int? port]) =>
        'http://127.0.0.1:${port ?? elsewhere.port}/a.tar.gz';

    App withHosts(List<String> hosts) {
      final limited = buildProxy(allowedArchiveHosts: hosts);
      addTearDown(limited.close);
      return buildApp(using: limited);
    }

    test('a listing pointing at another port is refused', () async {
      final other = await HttpServer.bind('localhost', 0);
      addTearDown(() => other.close(force: true));
      final requests = <String>[];
      other.listen((request) {
        requests.add(request.uri.path);
        request.response.close();
      });
      upstream.archiveUrlOf = (name, version) =>
          'http://localhost:${other.port}/storage/$name-$version.tar.gz';

      final response = await get(route);

      expect(response.statusCode, 502);
      expect(requests, isEmpty);
      expect(cachedFile('1.0.0').existsSync(), isFalse);
    });

    test('a listing pointing at another host is refused', () async {
      upstream.archiveUrlOf = (_, __) => elsewhereUrl();
      expect((await get(route)).statusCode, 502);
      expect(elsewhereRequests, isEmpty);
    });

    test('the listing itself still works', () async {
      upstream.archiveUrlOf = (_, __) => elsewhereUrl();
      expect((await get('/api/packages/$_name')).statusCode, 200);
    });

    test('a redirect to a host that is not allowed is refused', () async {
      upstream.redirects['/storage/$_name-1.0.0.tar.gz'] = elsewhereUrl();
      final response = await get(route);
      expect(response.statusCode, 502);
      expect(elsewhereRequests, isEmpty);
    });

    test('an allowed host works, directly and by redirect', () async {
      upstream.archiveUrlOf = (_, __) => elsewhereUrl();
      final direct = await get(route, using: withHosts(['127.0.0.1']));
      expect(await bytesOf(direct), upstream.packages[_name]!['1.0.0']);
      expect(elsewhereRequests, ['/a.tar.gz']);

      await cachedFile('1.0.0').delete();
      upstream.archiveUrlOf = null;
      upstream.redirects['/storage/$_name-1.0.0.tar.gz'] = elsewhereUrl();
      final redirected = await get(route, using: withHosts(['127.0.0.1']));
      expect(await bytesOf(redirected), upstream.packages[_name]!['1.0.0']);
      expect(elsewhereRequests, hasLength(2));
    });

    test('three redirects on the upstream are followed', () async {
      upstream.archiveUrlOf = (_, __) => '${upstream.url}/hop/1';
      upstream.redirects['/hop/1'] = '/hop/2';
      upstream.redirects['/hop/2'] = '${upstream.url}/hop/3';
      upstream.redirects['/hop/3'] = '/storage/$_name-1.0.0.tar.gz';

      expect(
          await bytesOf(await get(route)), upstream.packages[_name]!['1.0.0']);
    });

    test('a fourth redirect is refused', () async {
      upstream.archiveUrlOf = (_, __) => '${upstream.url}/hop/1';
      upstream.redirects['/hop/1'] = '/hop/2';
      upstream.redirects['/hop/2'] = '/hop/3';
      upstream.redirects['/hop/3'] = '/hop/4';
      upstream.redirects['/hop/4'] = '/storage/$_name-1.0.0.tar.gz';

      expect((await get(route)).statusCode, 502);
      expect(upstream.count('/storage/$_name-1.0.0.tar.gz'), 0);
    });

    test('a redirect from https to http is refused', () async {
      final seen = <Uri>[];
      final client = MockClient((request) async {
        seen.add(request.url);
        if (request.url.path == '/api/packages/$_name') {
          return http.Response(
              json.encode({
                'name': _name,
                'versions': [
                  {
                    'version': '1.0.0',
                    'pubspec': {'name': _name, 'version': '1.0.0'},
                    'archive_url': 'https://registry.test/a.tar.gz',
                    'archive_sha256': 'a' * 64,
                  },
                ],
              }),
              200);
        }
        return http.Response('', 302,
            headers: {'location': 'http://registry.test/a.tar.gz'});
      });
      final secure = UpstreamProxy(
        config: UpstreamConfig(
            url: Uri.parse('https://registry.test'),
            mode: UpstreamMode.proxy,
            allowedArchiveHosts: const ['registry.test']),
        cache: MongoUpstreamCacheStore(db),
        archives: FileStore(storage.path),
        client: client,
      );
      addTearDown(secure.close);

      expect(
          (await get(route, using: buildApp(using: secure))).statusCode, 502);
      expect(seen.map((uri) => uri.scheme), everyElement('https'));
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

    test('refuses a name in a fresh cache without asking', () async {
      await get('/api/packages/$_name');
      upstream.requests.clear();

      expect(await publishError(_name, '1.0.0'),
          contains('exists on the upstream registry'));
      expect(upstream.requests, isEmpty);
    });

    test('a stale cache asks the upstream, and a 404 accepts', () async {
      await get('/api/packages/$_name');
      upstream.packages.remove(_name);
      now = now.add(const Duration(minutes: 11));

      await publishLocally(_name, '1.0.0');

      expect(await localPackage(_name), isNotNull);
      expect(upstream.count('/api/packages/$_name'), 2);
    });

    test('a stale cache the upstream confirms is refused', () async {
      await get('/api/packages/$_name');
      now = now.add(const Duration(minutes: 11));

      expect(await publishError(_name, '1.0.0'),
          contains('exists on the upstream registry'));
      expect(upstream.count('/api/packages/$_name'), 2);
    });

    test('a 200 is remembered as a fresh entry', () async {
      expect(await publishError(_name, '1.0.0'),
          contains('exists on the upstream registry'));
      upstream.requests.clear();

      expect(await publishError(_name, '1.0.0'),
          contains('exists on the upstream registry'));
      expect(upstream.requests, isEmpty);
    });

    test('an outage answers a retryable 503, and recovery accepts', () async {
      upstream.failWith = 500;

      final outcome = await publishOutcome('brand_new', '1.0.0');

      expect(outcome.statusCode, 503);
      expect(
          json.decode(await outcome.readAsString())['error']['message'],
          'upstream registry unavailable, cannot verify that brand_new is '
          'free, try again');
      expect(await localPackage('brand_new'), isNull);
      expect(filesInStorage(), isEmpty);

      upstream.failWith = null;
      await publishLocally('brand_new', '1.0.0');
      expect(await localPackage('brand_new'), isNotNull);
    });

    test('recovery that finds the name upstream still refuses it', () async {
      upstream.failWith = 500;
      expect((await publishOutcome(_name, '1.0.0')).statusCode, 503);
      expect(await localPackage(_name), isNull);

      upstream.failWith = null;
      expect(await publishError(_name, '1.0.0'),
          contains('exists on the upstream registry'));
      expect(await localPackage(_name), isNull);
    });

    test('a stale cache during an outage does not accept', () async {
      await get('/api/packages/$_name');
      upstream.packages.remove(_name);
      upstream.failWith = 500;
      now = now.add(const Duration(minutes: 11));

      expect((await publishOutcome(_name, '1.0.0')).statusCode, 503);
      expect(await localPackage(_name), isNull);
    });

    test('an unreachable upstream does not accept', () async {
      await upstream.stop();
      expect((await publishOutcome('brand_new', '1.0.0')).statusCode, 503);
      expect(await localPackage('brand_new'), isNull);
    });

    test('a listing that is not JSON does not accept', () async {
      final fake = await shelf_io.serve(
          (_) => shelf.Response.ok('<html>maintenance</html>'), 'localhost', 0);
      addTearDown(() => fake.close(force: true));
      final broken = UpstreamProxy(
        config: UpstreamConfig(
            url: Uri.parse('http://localhost:${fake.port}'),
            mode: UpstreamMode.proxy),
        cache: MongoUpstreamCacheStore(db),
        archives: FileStore(storage.path),
      );
      addTearDown(broken.close);

      expect(
          (await publishOutcome('brand_new', '1.0.0',
                  using: buildApp(using: broken)))
              .statusCode,
          503);
      expect(await localPackage('brand_new'), isNull);
    });

    test('allowPublishWhenUnavailable accepts with a warning', () async {
      upstream.failWith = 500;
      final lenient = UpstreamProxy(
        config: UpstreamConfig(
          url: upstream.url,
          mode: UpstreamMode.proxy,
          allowPublishWhenUnavailable: true,
        ),
        cache: MongoUpstreamCacheStore(db),
        archives: FileStore(storage.path),
      );
      addTearDown(lenient.close);

      await publishLocally('brand_new', '1.0.0',
          using: buildApp(using: lenient));

      expect(await localPackage('brand_new'), isNotNull);
    });

    test('allowPublishWhenUnavailable still refuses a known name', () async {
      final lenient = UpstreamProxy(
        config: UpstreamConfig(
          url: upstream.url,
          mode: UpstreamMode.proxy,
          allowPublishWhenUnavailable: true,
        ),
        cache: MongoUpstreamCacheStore(db),
        archives: FileStore(storage.path),
      );
      addTearDown(lenient.close);

      expect(
          await publishError(_name, '1.0.0', using: buildApp(using: lenient)),
          contains('exists on the upstream registry'));
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

    group('an unrequested 304', () {
      setUp(() => upstream.alwaysNotModified = true);

      test('for a listing is a JSON 502', () async {
        final response = await get('/api/packages/$_name');
        expect(response.statusCode, 502);
        expect(json.decode(await response.readAsString())['error']['message'],
            contains('304'));
      });

      test('for advisories is a JSON 502', () async {
        upstream.failWith = 304;
        final response = await get('/api/packages/$_name/advisories');
        expect(response.statusCode, 502);
        expect(json.decode(await response.readAsString())['error']['message'],
            contains('304'));
      });

      test('when publishing is a retryable 503', () async {
        final outcome = await publishOutcome('brand_new', '1.0.0');
        expect(outcome.statusCode, 503);
        expect(
            json.decode(await outcome.readAsString())['error']['message'],
            'upstream registry unavailable, cannot verify that brand_new is '
            'free, try again');
        expect(await localPackage('brand_new'), isNull);
      });

      test('is not trusted for an entry that has no validator', () async {
        await MongoUpstreamCacheStore(db).write(
            UpstreamCacheEntry(
                key: _name,
                body: json.encode({
                  'name': _name,
                  'versions': <Object>[],
                  'isDiscontinued': false,
                }),
                fetchedAt: now.subtract(const Duration(minutes: 11))),
            now.add(const Duration(days: 1)));

        expect((await get('/api/packages/$_name')).statusCode, 502);
      });
    });

    test('nothing cached sends no If-None-Match', () async {
      await get('/api/packages/$_name');
      await get('/api/packages/$_name/advisories');
      expect(upstream.validators, everyElement(isNull));
    });

    test('a cached entry does send its validator once stale', () async {
      await getJson('/api/packages/$_name');
      now = now.add(const Duration(minutes: 11));
      await getJson('/api/packages/$_name');
      expect(upstream.validators.last, '"listing-$_name-a"');
    });

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

    for (final status in [404, 500]) {
      test('a $status whose body stalls fails within the timeout', () async {
        final stalling = await HttpServer.bind('localhost', 0);
        addTearDown(() => stalling.close(force: true));
        stalling.listen((request) async {
          request.response
            ..statusCode = status
            ..contentLength = 100
            ..write('partial');
          await request.response.flush();
          // The remaining 93 bytes never come.
        });
        final slow = UpstreamProxy(
          config: UpstreamConfig(
            url: Uri.parse('http://localhost:${stalling.port}'),
            mode: UpstreamMode.proxy,
            timeout: const Duration(milliseconds: 200),
          ),
          cache: MongoUpstreamCacheStore(db),
          archives: FileStore(storage.path),
        );
        addTearDown(slow.close);

        final watch = Stopwatch()..start();
        final response =
            await get('/api/packages/$_name', using: buildApp(using: slow));

        expect(response.statusCode, 502);
        expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      });
    }

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
      expect(response.headers['cache-control'], 'private, no-store');
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

    // Without --skip-validation pub stops earlier, at its own listing request,
    // which is answered 502 during an outage and is not accepted either.
    test('dart pub publish reports an upstream outage', () async {
      final proxied = App(
        metaStore: MongoStore(db),
        packageStore: FileStore(storage.path),
        authenticator: const FakeAuthenticator(testToken, 'dev@b.c'),
        upstreamProxy: proxy,
        upstream: upstream.url.toString(),
      );
      server = await proxied.serve('0.0.0.0', 4000);
      upstream.failWith = 503;

      final result = await pubPublishGenerated('brand_new', '1.0.0',
          arguments: ['--skip-validation']);

      expect(result.exitCode, isNot(0), reason: '${result.stdout}');
      expect(
          result.stderr,
          contains('upstream registry unavailable, cannot verify that '
              'brand_new is free, try again'));
      expect(await localPackage('brand_new'), isNull);
    }, timeout: const Timeout(Duration(minutes: 5)));

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
