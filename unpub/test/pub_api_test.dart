import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:mongo_dart/mongo_dart.dart';
import 'package:path/path.dart' as path;
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';
import 'package:unpub/unpub.dart';

import 'utils.dart';

const _password = 'correct-horse-battery';
const _pubClient = {'user-agent': 'Dart pub 3.12.0'};

/// A response with its body decoded.
class Reply {
  final int status;
  final Map<String, String> headers;
  final dynamic body;

  const Reply(this.status, this.headers, this.body);

  String? get error => body['error']?['message'] as String?;
}

void main() {
  late Db db;
  late Directory storage;
  late AccountStore store;
  late MongoAuditStore audit;
  late AccountService accounts;
  late App app;
  late String adminToken;
  late String ownerToken;

  const name = 'fine';

  Future<void> clean() async {
    for (final collection in [
      userCollection,
      tokenCollection,
      sessionCollection,
      adminSetCollection,
      auditCollection,
      packageCollection,
      statsCollection,
      versionStatsCollection,
    ]) {
      await db.dropCollection(collection);
    }
  }

  App buildApp({
    ReadAccess readAccess = ReadAccess.public,
    PublishConfig publish = const PublishConfig(),
  }) =>
      App(
        metaStore: MongoStore(db),
        packageStore: FileStore(storage.path),
        authenticator: ChainAuthenticator([
          ApiTokenAuthenticator(store),
          SessionAuthenticator(store),
        ]),
        readAccess: readAccess,
        accountApi: AccountApi(accounts, limiter: LoginRateLimiter()),
        auditStore: audit,
        publishPolicy: PublishPolicy(publish),
      );

  setUpAll(() async {
    db = Db(testMongoUri);
    await db.open();
  });

  tearDownAll(() async {
    await clean();
    await db.close();
  });

  Future<String> tokenFor(User user, {Set<Scope>? scopes}) async =>
      (await accounts.createToken(user,
              name: 'test', scopes: scopes ?? scopesAllowedFor(user.role)))
          .secret;

  Future<Reply> send(
    String method,
    String route, {
    String? bearer,
    Map<String, String> headers = const {},
    Object? jsonBody,
    App? using,
  }) async {
    final response = await (using ?? app).handler(shelf.Request(
      method,
      Uri.parse('http://internal:4000$route'),
      headers: {
        if (bearer != null) 'authorization': 'Bearer $bearer',
        ...headers,
      },
      body: jsonBody == null ? null : json.encode(jsonBody),
    ));
    final bytes = await response.read().expand((chunk) => chunk).toList();
    final text = utf8.decode(bytes, allowMalformed: true);
    Object? body;
    try {
      body = text.isEmpty ? null : json.decode(text);
    } on FormatException {
      body = text;
    }
    return Reply(response.statusCode, response.headers, body);
  }

  Future<void> publish(String version, {String? bearer}) async {
    final response = await app.handler(uploadRequest(
      'name: $name\nversion: $version\n',
      {'authorization': 'Bearer ${bearer ?? ownerToken}'},
    ));
    expect(response.headers['location'], isNot(contains('error')),
        reason: Uri.decodeFull(response.headers['location'] ?? ''));
  }

  Future<void> setCreatedAt(String version, DateTime at) =>
      db.collection(packageCollection).updateOne(
          where.eq('name', name).eq('versions.version', version),
          modify.set(r'versions.$.createdAt', at));

  Future<Map<String, dynamic>> storedVersion(String version) async {
    final package =
        await db.collection(packageCollection).findOne(where.eq('name', name));
    return (package!['versions'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((item) => item['version'] == version);
  }

  Future<List<Map<String, dynamic>>> auditEvents(String action) =>
      db.collection(auditCollection).find(where.eq('action', action)).toList();

  setUp(() async {
    await clean();
    storage = await Directory.systemTemp.createTemp('unpub-pub-api-');
    addTearDown(() => storage.delete(recursive: true));
    store = AccountStore(db);
    audit = MongoAuditStore(db);
    await store.ensureIndexes();
    await audit.ensureIndexes();
    await MongoStore(db).ensureIndexes();
    accounts = AccountService(store,
        audit: audit,
        hasher: const PasswordHasher(memoryKiB: 32, iterations: 1));
    app = buildApp();
    adminToken = await tokenFor(await accounts.createUser(
        email: 'admin@b.c', role: Role.admin, password: _password));
    ownerToken = await tokenFor(await accounts.createUser(
        email: 'owner@b.c', role: Role.publisher, password: _password));
  });

  group('latest', () {
    UnpubPackage packageOf(Map<String, bool> versions) => UnpubPackage(
          'p',
          [
            for (final entry in versions.entries)
              UnpubVersion(
                  entry.key, const {}, null, null, null, null, DateTime.now(),
                  isRetracted: entry.value),
          ],
          true,
          const [],
          DateTime.now(),
          DateTime.now(),
          0,
        );

    final cases = <String, (Map<String, bool>, String)>{
      'the highest stable version': (
        {'1.0.0': false, '1.2.0': false, '1.1.0': false},
        '1.2.0'
      ),
      'stable over a higher prerelease': (
        {'1.0.0': false, '2.0.0-dev': false},
        '1.0.0'
      ),
      'the highest prerelease if only prereleases exist': (
        {'1.0.0-dev.1': false, '1.0.0-dev.2': false},
        '1.0.0-dev.2'
      ),
      'skips a retracted stable version': (
        {'1.0.0': false, '1.1.0': true},
        '1.0.0'
      ),
      'a prerelease when every stable version is retracted': (
        {'1.0.0': true, '2.0.0-dev': false},
        '2.0.0-dev'
      ),
      'skips a retracted prerelease': (
        {'1.0.0-dev.1': false, '1.0.0-dev.2': true},
        '1.0.0-dev.1'
      ),
      'the highest version when everything is retracted': (
        {'1.0.0': true, '2.0.0-dev': true, '1.5.0': true},
        '2.0.0-dev'
      ),
      'orders build numbers': ({'1.0.0': false, '1.0.0+2': false}, '1.0.0+2'),
    };

    cases.forEach((description, data) {
      test(description, () {
        expect(packageOf(data.$1).latest.version, data.$2);
      });
    });
  });

  group('version listing', () {
    test('describes each version and the package', () async {
      await publish('1.0.0');
      await publish('2.0.0-dev');

      final reply = await send('GET', '/api/packages/$name');

      expect(reply.status, 200);
      final body = reply.body as Map;
      expect(body['name'], name);
      expect(body['isDiscontinued'], isFalse);
      expect(body.containsKey('replacedBy'), isFalse);
      expect(body['latest']['version'], '1.0.0');
      final first = (body['versions'] as List)
          .singleWhere((item) => item['version'] == '1.0.0');
      expect(first['archive_url'],
          'http://internal:4000/packages/$name/versions/1.0.0.tar.gz');
      expect(first['pubspec']['name'], name);
      expect(first['archive_sha256'], matches(r'^[0-9a-f]{64}$'));
      expect(DateTime.parse(first['published'] as String).isUtc, isTrue);
      expect(first.containsKey('retracted'), isFalse);
    });

    test('archive_sha256 is the hash of the stored file', () async {
      await publish('1.0.0');
      final sha = (await storedVersion('1.0.0'))['sha256'] as String;
      final bytes =
          File(path.join(storage.path, name, '$name-1.0.0-$sha.tar.gz'))
              .readAsBytesSync();
      final reply = await send('GET', '/api/packages/$name');
      expect(reply.body['latest']['archive_sha256'],
          crypto.sha256.convert(bytes).toString());
      expect((await storedVersion('1.0.0'))['sha256'],
          crypto.sha256.convert(bytes).toString());
    });

    test('omits archive_sha256 for a version without a stored hash', () async {
      await publish('1.0.0');
      await db.collection(packageCollection).updateOne(
          where.eq('name', name), modify.unset(r'versions.0.sha256'));

      final reply = await send('GET', '/api/packages/$name');

      expect(reply.status, 200);
      expect(reply.body['latest'].containsKey('archive_sha256'), isFalse);
    });

    test('documents written before this version still read', () async {
      await db.collection(packageCollection).insertOne({
        'name': name,
        'uploaders': ['owner@b.c'],
        'private': true,
        'download': 0,
        'createdAt': DateTime.now(),
        'updatedAt': DateTime.now(),
        'versions': [
          {
            'version': '1.0.0',
            'pubspec': {'name': name},
            'createdAt': DateTime.now(),
          },
        ],
      });

      final reply = await send('GET', '/api/packages/$name');

      expect(reply.status, 200);
      expect(reply.body['isDiscontinued'], isFalse);
      expect(reply.body['latest'].containsKey('retracted'), isFalse);
    });

    test('the single version route has the same shape', () async {
      await publish('1.0.0');
      await send('POST', '/api/packages/$name/versions/1.0.0/retract',
          bearer: ownerToken);

      final reply = await send('GET', '/api/packages/$name/versions/1.0.0');

      expect(reply.status, 200);
      expect(reply.body['version'], '1.0.0');
      expect(reply.body['retracted'], isTrue);
      expect(reply.body['published'], isA<String>());
      expect(reply.body['archive_sha256'], matches(r'^[0-9a-f]{64}$'));
    });

    test('advisories of a local package are an empty list', () async {
      await publish('1.0.0');
      final reply = await send('GET', '/api/packages/$name/advisories');
      expect(reply.status, 200);
      expect(reply.body, {'advisories': [], 'advisoriesUpdated': null});
    });

    test('advisories of an unknown package redirect upstream', () async {
      final response = await app.handler(shelf.Request('GET',
          Uri.parse('http://internal:4000/api/packages/nope/advisories')));
      expect(response.statusCode, HttpStatus.found);
      expect(response.headers['location'],
          'https://pub.dev/api/packages/nope/advisories');
    });
  });

  group('http caching', () {
    const route = '/api/packages/$name';
    const tarball = '/packages/$name/versions/1.0.0.tar.gz';

    test('a listing has a validator and can be revalidated', () async {
      await publish('1.0.0');

      final first = await send('GET', route);
      final etag = first.headers['etag']!;
      expect(first.headers['cache-control'], 'public, max-age=60');

      final second = await send('GET', route, headers: {'if-none-match': etag});
      expect(second.status, 304);
      expect(second.headers['etag'], etag);
      expect(second.headers['cache-control'], 'public, max-age=60');
    });

    test('a validator made weak by a proxy still matches', () async {
      await publish('1.0.0');
      final etag = (await send('GET', route)).headers['etag']!;
      final weak = etag.startsWith('W/') ? etag : 'W/$etag';
      final reply = await send('GET', route, headers: {'if-none-match': weak});
      expect(reply.status, 304);
    });

    test('* and a list of validators are understood', () async {
      await publish('1.0.0');
      final etag = (await send('GET', route)).headers['etag']!;
      expect((await send('GET', route, headers: {'if-none-match': '*'})).status,
          304);
      expect(
          (await send('GET', route,
                  headers: {'if-none-match': '"other", $etag'}))
              .status,
          304);
      expect(
          (await send('GET', route, headers: {'if-none-match': '"other"'}))
              .status,
          200);
    });

    test('the validator changes with new versions and flags', () async {
      await publish('1.0.0');
      Future<String> current() async =>
          (await send('GET', route)).headers['etag']!;

      final seen = {await current()};
      Future<void> expectNew() async =>
          expect(seen.add(await current()), isTrue);

      await publish('1.1.0');
      await expectNew();
      await send('POST', '$route/versions/1.1.0/retract', bearer: ownerToken);
      await expectNew();
      await send('PUT', '$route/discontinue',
          bearer: ownerToken, jsonBody: {'isDiscontinued': true});
      await expectNew();
    });

    test('undoing a retraction brings back the same validator', () async {
      await publish('1.0.0');
      final before = (await send('GET', route)).headers['etag'];
      await send('POST', '$route/versions/1.0.0/retract', bearer: ownerToken);
      expect((await send('GET', route)).headers['etag'], isNot(before));
      await send('POST', '$route/versions/1.0.0/unretract', bearer: ownerToken);
      expect((await send('GET', route)).headers['etag'], before);
    });

    test('backfilling a hash changes the validator', () async {
      await publish('1.0.0');
      final before = (await send('GET', route)).headers['etag'];
      await db.collection(packageCollection).updateOne(
          where.eq('name', name), modify.unset(r'versions.0.sha256'));
      expect((await send('GET', route)).headers['etag'], isNot(before));
    });

    test('the validator of a listing depends on the origin in it', () async {
      await publish('1.0.0');
      final other = App(
        metaStore: MongoStore(db),
        packageStore: FileStore(storage.path),
        authenticator: ChainAuthenticator([ApiTokenAuthenticator(store)]),
        publicUrl: Uri.parse('https://pub.example.com'),
      );
      expect((await send('GET', route, using: other)).headers['etag'],
          isNot((await send('GET', route)).headers['etag']));
    });

    test('a private registry forbids caching listings', () async {
      await publish('1.0.0');
      final private = buildApp(readAccess: ReadAccess.authenticated);
      final reply =
          await send('GET', route, bearer: ownerToken, using: private);
      expect(reply.status, 200);
      expect(reply.headers['cache-control'], 'private, no-store');
      expect(reply.headers['etag'], isNotNull);
    });

    test('an archive has a strong validator and can be revalidated', () async {
      await publish('1.0.0');
      final hash = (await storedVersion('1.0.0'))['sha256'];

      final first = await send('GET', tarball);
      expect(first.status, 200);
      expect(first.headers['etag'], '"$hash"');
      expect(first.headers['cache-control'],
          'public, max-age=31536000, immutable');

      final second =
          await send('GET', tarball, headers: {'if-none-match': '"$hash"'});
      expect(second.status, 304);
      expect(second.headers['etag'], '"$hash"');
    });

    test('an archive that cannot be replaced is immutable', () async {
      await publish('1.0.0');
      final reply = await send('GET', tarball);
      expect(reply.headers['cache-control'],
          'public, max-age=31536000, immutable');
    });

    test('an archive that can be replaced is cached briefly', () async {
      await publish('1.0.0');
      final replaceable =
          buildApp(publish: const PublishConfig(requireVersionBump: false));
      final reply = await send('GET', tarball, using: replaceable);
      expect(reply.headers['cache-control'], 'public, max-age=60');
    });

    test('a private registry ignores requireVersionBump', () async {
      await publish('1.0.0');
      final private = buildApp(
          readAccess: ReadAccess.authenticated,
          publish: const PublishConfig(requireVersionBump: false));
      final reply =
          await send('GET', tarball, bearer: ownerToken, using: private);
      expect(reply.headers['cache-control'], 'private, no-store');
    });

    test('an archive without a stored hash has no validator', () async {
      await publish('1.0.0');
      await db.collection(packageCollection).updateOne(
          where.eq('name', name), modify.unset(r'versions.0.sha256'));
      // A version from before hashes were recorded is at the legacy path.
      File(path.join(storage.path, '$name-1.0.0.tar.gz'))
          .writeAsStringSync('legacy');
      final reply = await send('GET', tarball);
      expect(reply.status, 200);
      expect(reply.headers.containsKey('etag'), isFalse);
    });

    test('a private registry marks archives private', () async {
      await publish('1.0.0');
      final private = buildApp(readAccess: ReadAccess.authenticated);
      final reply =
          await send('GET', tarball, bearer: ownerToken, using: private);
      expect(reply.headers['cache-control'], 'private, no-store');
    });

    Future<int?> countOf(String field) async {
      final stats = await db
          .collection(versionStatsCollection)
          .findOne(where.eq('name', name).eq('version', '1.0.0'));
      return stats?[field] as int?;
    }

    Future<void> waitForCount(int expected) async {
      for (var i = 0; i < 100 && await countOf('count') != expected; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await countOf('count'), expected);
    }

    test('a 304 is not counted as a download', () async {
      await publish('1.0.0');
      final hash = (await storedVersion('1.0.0'))['sha256'];

      await send('GET', tarball, headers: _pubClient);
      await waitForCount(1);

      final reply = await send('GET', tarball,
          headers: {..._pubClient, 'if-none-match': '"$hash"'});
      expect(reply.status, 304);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await waitForCount(1);
      final package = await db
          .collection(packageCollection)
          .findOne(where.eq('name', name));
      expect(package!['download'], 1);
    });

    test('only pub clients are counted', () async {
      await publish('1.0.0');
      await send('GET', tarball);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await countOf('count'), isNull);
    });

    test('a HEAD request is not counted', () async {
      await publish('1.0.0');
      final reply = await send('HEAD', tarball, headers: _pubClient);
      expect(reply.status, 200);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await countOf('count'), isNull);
    });

    test('per version counts keep daily counters and a total', () async {
      await publish('1.0.0');
      await send('GET', tarball, headers: _pubClient);
      await waitForCount(1);
      await send('GET', tarball, headers: _pubClient);
      await waitForCount(2);

      final today = DateFormat('yyyyMMdd').format(DateTime.now());
      expect(await countOf('d$today'), 2);
      expect(
          await db
              .collection(versionStatsCollection)
              .count(where.eq('name', name)),
          1);
    });

    test('the detail view reports version and package downloads', () async {
      await publish('1.0.0');
      await publish('1.1.0');
      await send('GET', tarball, headers: _pubClient);
      await waitForCount(1);

      final detail = await send('GET', '/webapi/package/$name/1.0.0');
      expect(detail.body['data']['downloads'], {'version': 1, 'package': 1});

      final other = await send('GET', '/webapi/package/$name/1.1.0');
      expect(other.body['data']['downloads'], {'version': 0, 'package': 1});
    });

    test('the detail view reports downloads and uploader per version',
        () async {
      await publish('1.0.0');
      await publish('1.1.0');
      await send('GET', tarball, headers: _pubClient);
      await waitForCount(1);

      final detail = await send('GET', '/webapi/package/$name/1.0.0');

      final versions = (detail.body['data']['versions'] as List)
          .cast<Map<String, dynamic>>();
      expect(versions.map((v) => v['version']), ['1.1.0', '1.0.0']);
      expect(versions.map((v) => v['downloads']), [0, 1]);
      expect(versions.map((v) => v['uploader']), ['owner@b.c', 'owner@b.c']);
      expect(versions.first['createdAt'], isA<String>());
      expect(versions.first['isRetracted'], isFalse);
    });

    test('the package list reports the downloads of each package', () async {
      await publish('1.0.0');
      await send('GET', tarball, headers: _pubClient);
      await waitForCount(1);

      final list = await send('GET', '/webapi/packages');

      expect(list.body['data']['packages'].single['downloads'], 1);
    });

    test('the detail view reports when a package was discontinued', () async {
      await publish('1.0.0');
      final route = '/webapi/package/$name/latest';
      expect((await send('GET', route)).body['data']['discontinuedAt'], isNull);

      await send('PUT', '/api/packages/$name/discontinue',
          bearer: ownerToken, jsonBody: {'isDiscontinued': true});

      final detail = await send('GET', route);
      expect(DateTime.parse(detail.body['data']['discontinuedAt'] as String),
          isA<DateTime>());
      expect(detail.body['data']['isDiscontinued'], isTrue);
    });
  });

  group('retraction', () {
    String retract(String version) =>
        '/api/packages/$name/versions/$version/retract';
    String unretract(String version) =>
        '/api/packages/$name/versions/$version/unretract';

    test('marks the version and leaves it out of latest', () async {
      await publish('1.0.0');
      await publish('1.1.0');

      final reply = await send('POST', retract('1.1.0'), bearer: ownerToken);
      expect(reply.status, 200);

      final listing = await send('GET', '/api/packages/$name');
      expect(listing.body['latest']['version'], '1.0.0');
      final retracted = (listing.body['versions'] as List)
          .singleWhere((item) => item['version'] == '1.1.0');
      expect(retracted['retracted'], isTrue);

      final stored = await storedVersion('1.1.0');
      expect(stored['isRetracted'], isTrue);
      expect(stored['retractedAt'], isA<DateTime>());
      expect(stored['retractedBy'], 'owner@b.c');
      expect(
          (await storedVersion('1.0.0')).containsKey('isRetracted'), isFalse);
    });

    test('the only version can be retracted and stays latest', () async {
      await publish('1.0.0');
      expect((await send('POST', retract('1.0.0'), bearer: ownerToken)).status,
          200);
      final listing = await send('GET', '/api/packages/$name');
      expect(listing.body['latest']['version'], '1.0.0');
      expect(listing.body['latest']['retracted'], isTrue);
    });

    test('a retracted version can still be downloaded', () async {
      await publish('1.0.0');
      await send('POST', retract('1.0.0'), bearer: ownerToken);
      expect(
          (await send('GET', '/packages/$name/versions/1.0.0.tar.gz')).status,
          200);
    });

    test('unretract restores the version and clears the fields', () async {
      await publish('1.0.0');
      await send('POST', retract('1.0.0'), bearer: ownerToken);

      final reply = await send('POST', unretract('1.0.0'), bearer: ownerToken);

      expect(reply.status, 200);
      final stored = await storedVersion('1.0.0');
      expect(stored.containsKey('isRetracted'), isFalse);
      expect(stored.containsKey('retractedAt'), isFalse);
      expect(stored.containsKey('retractedBy'), isFalse);
    });

    test('is audited once, not on a repeat', () async {
      await publish('1.0.0');
      await send('POST', retract('1.0.0'), bearer: ownerToken);
      final again = await send('POST', retract('1.0.0'), bearer: ownerToken);
      expect(again.status, 200);

      final events = await auditEvents('version.retracted');
      expect(events, hasLength(1));
      expect(events.single['target'], '$name@1.0.0');
      expect(events.single['actor'], startsWith('token:'));

      await send('POST', unretract('1.0.0'), bearer: ownerToken);
      expect(await auditEvents('version.unretracted'), hasLength(1));
    });

    test('an unknown version is a 404', () async {
      await publish('1.0.0');
      final reply = await send('POST', retract('9.9.9'), bearer: ownerToken);
      expect(reply.status, 404);
      expect(reply.error, isNotNull);
    });

    test('a version with build metadata can be retracted', () async {
      await publish('1.0.0+1');
      final reply =
          await send('POST', retract('1.0.0%2B1'), bearer: ownerToken);
      expect(reply.status, 200);
      expect((await storedVersion('1.0.0+1'))['isRetracted'], isTrue);
    });

    test('anonymous requests are refused', () async {
      await publish('1.0.0');
      expect((await send('POST', retract('1.0.0'))).status, 401);
      expect((await send('POST', unretract('1.0.0'))).status, 401);
    });

    test('a reader token cannot retract', () async {
      await publish('1.0.0');
      final reader = await tokenFor(
          await accounts.createUser(email: 'r@b.c', role: Role.reader));
      final reply = await send('POST', retract('1.0.0'), bearer: reader);
      expect(reply.status, 403);
      expect(
          (await storedVersion('1.0.0')).containsKey('isRetracted'), isFalse);
    });

    test('a token without the publish scope cannot retract', () async {
      await publish('1.0.0');
      final owner = (await store.findUserByEmail('owner@b.c'))!;
      final readOnly = await tokenFor(owner, scopes: {Scope.read});
      final reply = await send('POST', retract('1.0.0'), bearer: readOnly);
      expect(reply.status, 403);
    });

    test('a publisher who is not an uploader cannot retract', () async {
      await publish('1.0.0');
      final other = await tokenFor(
          await accounts.createUser(email: 'o@b.c', role: Role.publisher));
      for (final route in [retract('1.0.0'), unretract('1.0.0')]) {
        final reply = await send('POST', route, bearer: other);
        expect(reply.status, 403);
        expect(reply.error, 'no permission');
      }
      expect(
          (await storedVersion('1.0.0')).containsKey('isRetracted'), isFalse);
    });

    test('an administrator can retract any package', () async {
      await publish('1.0.0');
      final reply = await send('POST', retract('1.0.0'), bearer: adminToken);
      expect(reply.status, 200);
      expect((await storedVersion('1.0.0'))['retractedBy'], 'admin@b.c');
    });

    test('a session with its CSRF token can retract', () async {
      await publish('1.0.0');
      final login = await app.handler(shelf.Request(
          'POST', Uri.parse('http://internal:4000/webapi/login'),
          headers: {'content-type': 'application/json'},
          body: json.encode({'email': 'owner@b.c', 'password': _password})));
      final cookie = login.headers['set-cookie']!.split(';').first;
      final csrf =
          json.decode(await login.readAsString())['csrfToken'] as String;

      final refused =
          await send('POST', retract('1.0.0'), headers: {'cookie': cookie});
      expect(refused.status, 403);

      final accepted = await send('POST', retract('1.0.0'),
          headers: {'cookie': cookie, 'x-csrf-token': csrf});
      expect(accepted.status, 200);
    });

    group('window', () {
      final old = DateTime.now().subtract(const Duration(days: 8));

      test('refuses a non-administrator after it closed', () async {
        await publish('1.0.0');
        await setCreatedAt('1.0.0', old);

        final reply = await send('POST', retract('1.0.0'), bearer: ownerToken);

        expect(reply.status, 403);
        expect(reply.error, contains('publish.retractionWindow'));
        expect(
            (await storedVersion('1.0.0')).containsKey('isRetracted'), isFalse);
      });

      test('allows a non-administrator while it is open', () async {
        await publish('1.0.0');
        await setCreatedAt(
            '1.0.0', DateTime.now().subtract(const Duration(days: 6)));
        expect(
            (await send('POST', retract('1.0.0'), bearer: ownerToken)).status,
            200);
      });

      test('does not apply to an administrator', () async {
        await publish('1.0.0');
        await setCreatedAt('1.0.0', old);
        expect(
            (await send('POST', retract('1.0.0'), bearer: adminToken)).status,
            200);
      });

      test('can be configured, and null means unlimited', () async {
        await publish('1.0.0');
        await setCreatedAt('1.0.0', old);
        final unlimited =
            buildApp(publish: const PublishConfig(retractionWindow: null));
        expect(
            (await send('POST', retract('1.0.0'),
                    bearer: ownerToken, using: unlimited))
                .status,
            200);
      });

      test('does not stop an uploader from restoring a version', () async {
        await publish('1.0.0');
        await send('POST', retract('1.0.0'), bearer: ownerToken);
        await setCreatedAt('1.0.0', old);
        expect(
            (await send('POST', unretract('1.0.0'), bearer: ownerToken)).status,
            200);
      });
    });
  });

  group('discontinue', () {
    const route = '/api/packages/$name/discontinue';

    test('sets the flag and replacedBy, visible in the listing', () async {
      await publish('1.0.0');

      final reply = await send('PUT', route,
          bearer: ownerToken,
          jsonBody: {'isDiscontinued': true, 'replacedBy': 'better'});
      expect(reply.status, 200);

      final listing = await send('GET', '/api/packages/$name');
      expect(listing.body['isDiscontinued'], isTrue);
      expect(listing.body['replacedBy'], 'better');

      final stored = await db
          .collection(packageCollection)
          .findOne(where.eq('name', name));
      expect(stored!['discontinuedAt'], isA<DateTime>());
      expect(await auditEvents('package.discontinued'), hasLength(1));
    });

    test('a discontinued package still serves everything', () async {
      await publish('1.0.0');
      await send('PUT', route,
          bearer: ownerToken, jsonBody: {'isDiscontinued': true});
      expect(
          (await send('GET', '/packages/$name/versions/1.0.0.tar.gz')).status,
          200);
    });

    test('clearing the flag removes all three fields', () async {
      await publish('1.0.0');
      await send('PUT', route,
          bearer: ownerToken,
          jsonBody: {'isDiscontinued': true, 'replacedBy': 'better'});
      final reply = await send('PUT', route,
          bearer: ownerToken, jsonBody: {'isDiscontinued': false});
      expect(reply.status, 200);

      final stored = await db
          .collection(packageCollection)
          .findOne(where.eq('name', name));
      for (final field in ['isDiscontinued', 'replacedBy', 'discontinuedAt']) {
        expect(stored!.containsKey(field), isFalse, reason: field);
      }
      expect((await send('GET', '/api/packages/$name')).body['isDiscontinued'],
          isFalse);
    });

    test('a later change keeps when it was discontinued', () async {
      await publish('1.0.0');
      await send('PUT', route,
          bearer: ownerToken, jsonBody: {'isDiscontinued': true});
      final first = (await db
          .collection(packageCollection)
          .findOne(where.eq('name', name)))!['discontinuedAt'];

      await send('PUT', route,
          bearer: ownerToken,
          jsonBody: {'isDiscontinued': true, 'replacedBy': 'better'});

      final stored = await db
          .collection(packageCollection)
          .findOne(where.eq('name', name));
      expect(stored!['discontinuedAt'], first);
      expect(stored['replacedBy'], 'better');
    });

    final badBodies = <String, Object?>{
      'not json': null,
      'no flag': {'replacedBy': 'better'},
      'a flag of the wrong type': {'isDiscontinued': 'yes'},
      'an invalid replacement': {
        'isDiscontinued': true,
        'replacedBy': 'Bad-Name'
      },
      'a replacement of the wrong type': {
        'isDiscontinued': true,
        'replacedBy': 1
      },
      'a package replacing itself': {
        'isDiscontinued': true,
        'replacedBy': name
      },
      'a replacement while not discontinued': {
        'isDiscontinued': false,
        'replacedBy': 'better',
      },
    };

    badBodies.forEach((description, body) {
      test('$description is a 400', () async {
        await publish('1.0.0');
        final reply =
            await send('PUT', route, bearer: ownerToken, jsonBody: body);
        expect(reply.status, 400);
        expect(reply.error, isNotNull);
      });
    });

    test('anonymous requests are refused', () async {
      expect(
          (await send('PUT', route, jsonBody: {'isDiscontinued': true})).status,
          401);
    });

    test('a reader token cannot discontinue', () async {
      await publish('1.0.0');
      final reader = await tokenFor(
          await accounts.createUser(email: 'r@b.c', role: Role.reader));
      final reply = await send('PUT', route,
          bearer: reader, jsonBody: {'isDiscontinued': true});
      expect(reply.status, 403);
    });

    test('a publisher who is not an uploader cannot discontinue', () async {
      await publish('1.0.0');
      final other = await tokenFor(
          await accounts.createUser(email: 'o@b.c', role: Role.publisher));
      final reply = await send('PUT', route,
          bearer: other, jsonBody: {'isDiscontinued': true});
      expect(reply.status, 403);
    });

    test('an administrator can discontinue any package', () async {
      await publish('1.0.0');
      final reply = await send('PUT', route,
          bearer: adminToken, jsonBody: {'isDiscontinued': true});
      expect(reply.status, 200);
    });

    test('only an administrator learns a package does not exist', () async {
      final asAdmin = await send('PUT', '/api/packages/nope/discontinue',
          bearer: adminToken, jsonBody: {'isDiscontinued': true});
      expect(asAdmin.status, 404);
      final asOwner = await send('PUT', '/api/packages/nope/discontinue',
          bearer: ownerToken, jsonBody: {'isDiscontinued': true});
      expect(asOwner.status, 403);
    });
  });

  group('web api', () {
    Future<void> discontinueFine() =>
        send('PUT', '/api/packages/$name/discontinue',
            bearer: ownerToken,
            jsonBody: {'isDiscontinued': true, 'replacedBy': 'better'});

    test('the package list hides discontinued packages by default', () async {
      await publish('1.0.0');
      await discontinueFine();

      final hidden = await send('GET', '/webapi/packages');
      expect(hidden.body['data']['count'], 0);

      final shown = await send('GET', '/webapi/packages?discontinued=true');
      expect(shown.body['data']['count'], 1);
      final item = shown.body['data']['packages'][0];
      expect(item['isDiscontinued'], isTrue);
      expect(item['replacedBy'], 'better');
    });

    test('the package list shows the latest version by the new rule', () async {
      await publish('1.0.0');
      await publish('1.1.0');
      await send('POST', '/api/packages/$name/versions/1.1.0/retract',
          bearer: ownerToken);
      final list = await send('GET', '/webapi/packages');
      expect(list.body['data']['packages'][0]['latest'], '1.0.0');
    });

    test('the detail view carries the flags', () async {
      await publish('1.0.0');
      await publish('1.1.0');
      await send('POST', '/api/packages/$name/versions/1.1.0/retract',
          bearer: ownerToken);
      await discontinueFine();

      final latest = await send('GET', '/webapi/package/$name/latest');
      expect(latest.body['data']['version'], '1.0.0');
      expect(latest.body['data']['isRetracted'], isFalse);
      expect(latest.body['data']['isDiscontinued'], isTrue);
      expect(latest.body['data']['replacedBy'], 'better');

      final retracted = await send('GET', '/webapi/package/$name/1.1.0');
      expect(retracted.body['data']['isRetracted'], isTrue);
      expect(retracted.body['data']['retractedAt'], isNotNull);
      final versions = retracted.body['data']['versions'] as List;
      expect(
          versions.singleWhere((v) => v['version'] == '1.1.0')['isRetracted'],
          isTrue);
    });
  });

  group('dart pub', () {
    late HttpServer server;
    const package = 'retract_me';

    setUpAll(setUpPubClient);
    tearDownAll(tearDownPubClient);

    setUp(() async {
      server = await createServer(email0);
    });

    tearDown(() => server.close());

    Future<http.Response> post(String route) => http.post(
          baseUri.resolve(route),
          headers: {HttpHeaders.authorizationHeader: 'Bearer $testToken'},
        );

    void expectOk(ProcessResult result) =>
        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');

    test('latest skips prereleases and a new project resolves to it', () async {
      expectOk(await pubPublishGenerated(package, '1.0.0'));
      expectOk(await pubPublishGenerated(package, '2.0.0-dev.1'));

      final listing = json.decode((await getVersions(package)).body);
      expect(listing['latest']['version'], '1.0.0');

      final consumer = await createConsumer(package, 'any');
      expectOk(await pubGet(consumer));
      expect(lockedVersion(consumer, package), '1.0.0');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('only prereleases resolve when asked for', () async {
      expectOk(await pubPublishGenerated(package, '1.0.0-dev.1'));
      expectOk(await pubPublishGenerated(package, '1.0.0-dev.2'));

      final listing = json.decode((await getVersions(package)).body);
      expect(listing['latest']['version'], '1.0.0-dev.2');

      final consumer = await createConsumer(package, '^1.0.0-dev.1');
      expectOk(await pubGet(consumer));
      expect(lockedVersion(consumer, package), '1.0.0-dev.2');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('a retracted version is not picked, but a lockfile keeps it',
        () async {
      expectOk(await pubPublishGenerated(package, '1.0.0'));
      expectOk(await pubPublishGenerated(package, '1.1.0'));

      final locked = await createConsumer(package, '^1.0.0');
      expectOk(await pubGet(locked));
      expect(lockedVersion(locked, package), '1.1.0');

      final response =
          await post('/api/packages/$package/versions/1.1.0/retract');
      expect(response.statusCode, 200, reason: response.body);
      await clearPubListingCache();

      final fresh = await createConsumer(package, '^1.0.0');
      expectOk(await pubGet(fresh));
      expect(lockedVersion(fresh, package), '1.0.0');

      expectOk(await pubGet(locked));
      expect(lockedVersion(locked, package), '1.1.0');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('a discontinued package is flagged and still resolves', () async {
      expectOk(await pubPublishGenerated(package, '1.0.0'));
      final response = await http.put(
        baseUri.resolve('/api/packages/$package/discontinue'),
        headers: {HttpHeaders.authorizationHeader: 'Bearer $testToken'},
        body: json.encode({'isDiscontinued': true, 'replacedBy': 'better'}),
      );
      expect(response.statusCode, 200, reason: response.body);

      final listing = json.decode((await getVersions(package)).body);
      expect(listing['isDiscontinued'], isTrue);
      expect(listing['replacedBy'], 'better');

      await clearPubListingCache();
      final consumer = await createConsumer(package, 'any');
      expectOk(await pubGet(consumer));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('archive_sha256 satisfies the client', () async {
      expectOk(await pubPublishGenerated(package, '1.0.0'));
      final listing = json.decode((await getVersions(package)).body);
      final consumer = await createConsumer(package, '1.0.0');
      expectOk(await pubGet(consumer));
      final lock =
          File(path.join(consumer.path, 'pubspec.lock')).readAsStringSync();
      expect(lock, contains(listing['latest']['archive_sha256'] as String));
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
