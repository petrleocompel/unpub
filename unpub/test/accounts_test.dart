import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:mongo_dart/mongo_dart.dart';
import 'package:path/path.dart' as path;
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';
import 'package:unpub/unpub.dart';

import 'utils.dart';

const _password = 'correct-horse-battery';

/// A response with its body decoded.
class Reply {
  final int status;
  final Map<String, String> headers;
  final dynamic body;

  const Reply(this.status, this.headers, this.body);

  String? get errorCode => body['error']?['code'] as String?;
}

/// What a browser holds after logging in.
class Browser {
  final String cookie;
  final String csrf;

  const Browser(this.cookie, this.csrf);
}

void main() {
  late Db db;
  late Directory storage;
  late AccountStore store;
  late MongoAuditStore audit;
  late AccountService accounts;
  late App app;

  Future<void> clean() async {
    for (final name in [
      userCollection,
      tokenCollection,
      sessionCollection,
      adminSetCollection,
      auditCollection,
      packageCollection,
      statsCollection,
    ]) {
      await db.dropCollection(name);
    }
  }

  App buildApp({
    ReadAccess readAccess = ReadAccess.public,
    String? bootstrapToken,
    Set<String> readTokens = const {},
    LoginRateLimiter? limiter,
    bool secureCookies = false,
  }) =>
      App(
        metaStore: MongoStore(db),
        packageStore: FileStore(storage.path),
        authenticator: ChainAuthenticator([
          ApiTokenAuthenticator(store),
          SessionAuthenticator(store),
          StaticTokenAuthenticator(
            bootstrapToken: bootstrapToken,
            bootstrapEmail: 'ops@example.com',
            readTokens: readTokens,
          ),
        ]),
        readAccess: readAccess,
        accountApi: AccountApi(
          accounts,
          limiter: limiter ?? LoginRateLimiter(),
          secureCookies: secureCookies,
          trustForwardedFor: true,
        ),
        auditStore: audit,
        trustForwardedFor: true,
      );

  setUpAll(() async {
    db = Db(testMongoUri);
    await db.open();
    storage = await Directory.systemTemp.createTemp('unpub-accounts-');
  });

  tearDownAll(() async {
    await clean();
    await db.close();
    await storage.delete(recursive: true);
  });

  setUp(() async {
    await clean();
    store = AccountStore(db);
    audit = MongoAuditStore(db);
    await store.ensureIndexes();
    await audit.ensureIndexes();
    accounts = AccountService(store,
        audit: audit,
        hasher: const PasswordHasher(memoryKiB: 32, iterations: 1));
    app = buildApp();
  });

  Future<Reply> decode(shelf.Response response) async {
    final text = await response.readAsString();
    Object? body;
    try {
      body = text.isEmpty ? null : json.decode(text);
    } on FormatException {
      body = text;
    }
    return Reply(response.statusCode, response.headers, body);
  }

  Future<Reply> send(
    String method,
    String route, {
    String? bearer,
    Browser? browser,
    bool sendCsrf = true,
    Map<String, Object?>? body,
    String? form,
    Map<String, String> headers = const {},
    App? using,
  }) async {
    return decode(await (using ?? app).handler(shelf.Request(
      method,
      Uri.parse('http://internal:4000$route'),
      headers: {
        if (bearer != null) 'authorization': 'Bearer $bearer',
        if (browser != null) 'cookie': '$sessionCookieName=${browser.cookie}',
        if (browser != null && sendCsrf && method != 'GET')
          'x-csrf-token': browser.csrf,
        if (body != null) 'content-type': 'application/json',
        if (form != null) 'content-type': 'application/x-www-form-urlencoded',
        ...headers,
      },
      body: body != null ? json.encode(body) : form,
    )));
  }

  Future<User> user(String email, Role role, {String? password = _password}) =>
      accounts.createUser(email: email, role: role, password: password);

  Future<String> token(User owner, {Set<Scope>? scopes}) async =>
      (await accounts.createToken(owner, name: 'test', scopes: scopes)).secret;

  Future<Browser> login(User user, {App? using}) async {
    final reply = await send('POST', '/webapi/login',
        body: {'email': user.email, 'password': _password}, using: using);
    expect(reply.status, HttpStatus.ok, reason: '${reply.body}');
    final cookie = RegExp('$sessionCookieName=([^;]+)')
        .firstMatch(reply.headers['set-cookie']!)!
        .group(1)!;
    return Browser(cookie, reply.body['csrfToken'] as String);
  }

  String pubspec(String name, String version) =>
      'name: $name\nversion: $version\n';

  /// Publishes an archive and returns the error the client would be shown,
  /// or null on success.
  Future<String?> publish(
    String name,
    String version, {
    String? bearer,
  }) async {
    final response = await app.handler(uploadRequest(pubspec(name, version),
        {if (bearer != null) 'authorization': 'Bearer $bearer'}));
    if (response.statusCode != HttpStatus.found) {
      fail('upload answered ${response.statusCode}');
    }
    final location = Uri.parse(response.headers['location']!);
    return location.queryParameters['error'];
  }

  /// The status of the upload request itself, for credentials it refuses.
  Future<int> uploadStatus(String name, {String? bearer}) async {
    final response = await app.handler(uploadRequest(pubspec(name, '1.0.0'),
        {if (bearer != null) 'authorization': 'Bearer $bearer'}));
    return response.statusCode;
  }

  Future<Map<String, dynamic>?> package(String name) =>
      db.collection(packageCollection).findOne(where.eq('name', name));

  Future<void> addPackage(String name, List<String>? uploaders) =>
      db.collection(packageCollection).insertOne({
        'name': name,
        'versions': [
          {
            'version': '0.0.1',
            'pubspec': {'name': name, 'version': '0.0.1'},
            'pubspecYaml': pubspec(name, '0.0.1'),
            'uploader': 'old@example.com',
            'createdAt': DateTime.now(),
          }
        ],
        'private': true,
        'download': 0,
        'createdAt': DateTime.now(),
        'updatedAt': DateTime.now(),
        if (uploaders != null) 'uploaders': uploaders,
      });

  Future<List<Map<String, dynamic>>> auditEvents(String action) =>
      db.collection(auditCollection).find(where.eq('action', action)).toList();

  group('publishing', () {
    test('an anonymous client cannot publish', () async {
      expect(await uploadStatus('fresh'), HttpStatus.unauthorized);
      expect(await package('fresh'), isNull);
    });

    test('a wrong token cannot publish', () async {
      expect(
          await uploadStatus('fresh', bearer: 'nope'), HttpStatus.unauthorized);
    });

    test('a reader cannot publish', () async {
      final reader = await user('r@b.c', Role.reader);
      expect(await uploadStatus('fresh', bearer: await token(reader)),
          HttpStatus.forbidden);
      expect(await package('fresh'), isNull);
    });

    test('a reader listed as uploader still cannot publish', () async {
      final reader = await user('r@b.c', Role.reader);
      await addPackage('owned', ['r@b.c']);
      expect(await uploadStatus('owned', bearer: await token(reader)),
          HttpStatus.forbidden);
    });

    test('a publisher can publish a new package and becomes its uploader',
        () async {
      final publisher = await user('p@b.c', Role.publisher);
      expect(await publish('fresh', '1.0.0', bearer: await token(publisher)),
          isNull);
      expect((await package('fresh'))!['uploaders'], ['p@b.c']);
    });

    test('a publisher can publish to a package they upload', () async {
      final publisher = await user('p@b.c', Role.publisher);
      await addPackage('owned', ['p@b.c']);
      expect(await publish('owned', '1.0.0', bearer: await token(publisher)),
          isNull);
      expect((await package('owned'))!['versions'], hasLength(2));
    });

    test('the uploader match ignores case', () async {
      final publisher = await user('p@b.c', Role.publisher);
      await addPackage('owned', ['P@B.C']);
      expect(await publish('owned', '1.0.0', bearer: await token(publisher)),
          isNull);
      expect((await package('owned'))!['uploaders'], ['P@B.C']);
    });

    test('a publisher cannot publish to a foreign package', () async {
      final publisher = await user('p@b.c', Role.publisher);
      await addPackage('foreign', ['other@b.c']);
      expect(await publish('foreign', '1.0.0', bearer: await token(publisher)),
          contains('not an uploader'));
      expect((await package('foreign'))!['versions'], hasLength(1));
    });

    test('a publisher cannot publish to a package without uploaders', () async {
      final publisher = await user('p@b.c', Role.publisher);
      await addPackage('legacy', null);
      expect(await publish('legacy', '1.0.0', bearer: await token(publisher)),
          contains('not an uploader'));
      expect((await package('legacy'))!['versions'], hasLength(1));
    });

    test('an admin can publish to a foreign package without joining it',
        () async {
      final admin = await user('a@b.c', Role.admin);
      await addPackage('foreign', ['other@b.c']);
      expect(await publish('foreign', '1.0.0', bearer: await token(admin)),
          isNull);
      final stored = (await package('foreign'))!;
      expect(stored['versions'], hasLength(2));
      expect(stored['uploaders'], ['other@b.c']);
    });

    test('an admin can publish to a package without uploaders', () async {
      final admin = await user('a@b.c', Role.admin);
      await addPackage('legacy', null);
      expect(
          await publish('legacy', '1.0.0', bearer: await token(admin)), isNull);
      expect((await package('legacy'))!.containsKey('uploaders'), isFalse);
    });

    test('a session can reach the publish steps only with a publishing role',
        () async {
      final reader = await login(await user('r@b.c', Role.reader));
      final publisher = await login(await user('p@b.c', Role.publisher));
      expect(
          (await send('GET', '/api/packages/versions/new', browser: reader))
              .status,
          HttpStatus.forbidden);
      expect(
          (await send('GET', '/api/packages/versions/new', browser: publisher))
              .status,
          HttpStatus.ok);
    });

    test('a version upload records the publishing identity', () async {
      final publisher = await user('p@b.c', Role.publisher);
      await publish('fresh', '1.0.0', bearer: await token(publisher));
      final versions = (await package('fresh'))!['versions'] as List;
      expect(versions.single['uploader'], 'p@b.c');
    });
  });

  group('uploader management', () {
    Future<Reply> add(String name, String email,
            {String? bearer, Browser? browser}) =>
        send('POST', '/api/packages/$name/uploaders',
            bearer: bearer,
            browser: browser,
            form: 'email=${Uri.encodeQueryComponent(email)}');

    Future<Reply> remove(String name, String email, {String? bearer}) => send(
        'DELETE', '/api/packages/$name/uploaders/${Uri.encodeComponent(email)}',
        bearer: bearer);

    test('anonymous requests are unauthorized', () async {
      await addPackage('owned', ['p@b.c']);
      expect((await add('owned', 'new@b.c')).status, HttpStatus.unauthorized);
      expect((await remove('owned', 'p@b.c')).status, HttpStatus.unauthorized);
    });

    test('a reader cannot manage even when listed', () async {
      final reader = await user('r@b.c', Role.reader);
      final secret = await token(reader);
      await addPackage('owned', ['r@b.c']);
      expect((await add('owned', 'new@b.c', bearer: secret)).status,
          HttpStatus.forbidden);
    });

    test('a reader with a session cannot manage even when listed', () async {
      final browser = await login(await user('r@b.c', Role.reader));
      await addPackage('owned', ['r@b.c']);
      expect((await add('owned', 'new@b.c', browser: browser)).status,
          HttpStatus.forbidden);
    });

    test('an uploader can add and remove', () async {
      final publisher = await user('p@b.c', Role.publisher);
      final secret = await token(publisher);
      await addPackage('owned', ['p@b.c']);

      expect((await add('owned', 'New@B.c', bearer: secret)).status,
          HttpStatus.ok);
      expect((await package('owned'))!['uploaders'], ['p@b.c', 'new@b.c']);

      expect((await remove('owned', 'NEW@b.c', bearer: secret)).status,
          HttpStatus.ok);
      expect((await package('owned'))!['uploaders'], ['p@b.c']);
    });

    test('adding an address that differs only in case is a duplicate',
        () async {
      final publisher = await user('p@b.c', Role.publisher);
      await addPackage('owned', ['p@b.c', 'Old@B.c']);
      final reply =
          await add('owned', 'old@b.c', bearer: await token(publisher));
      expect(reply.status, HttpStatus.badRequest);
      expect(reply.body['error']['message'], 'email already exists');
    });

    test('a publisher cannot manage a foreign package', () async {
      final publisher = await user('p@b.c', Role.publisher);
      final secret = await token(publisher);
      await addPackage('foreign', ['other@b.c']);
      expect((await add('foreign', 'new@b.c', bearer: secret)).status,
          HttpStatus.forbidden);
      expect((await remove('foreign', 'other@b.c', bearer: secret)).status,
          HttpStatus.forbidden);
    });

    test('a publisher cannot manage a package without uploaders', () async {
      final publisher = await user('p@b.c', Role.publisher);
      await addPackage('legacy', null);
      expect(
          (await add('legacy', 'new@b.c', bearer: await token(publisher)))
              .status,
          HttpStatus.forbidden);
    });

    test('a publisher cannot probe for packages', () async {
      final publisher = await user('p@b.c', Role.publisher);
      expect(
          (await add('missing', 'new@b.c', bearer: await token(publisher)))
              .status,
          HttpStatus.forbidden);
    });

    test('an admin can manage any package', () async {
      final admin = await user('a@b.c', Role.admin);
      final secret = await token(admin);
      await addPackage('foreign', ['other@b.c']);
      expect((await add('foreign', 'new@b.c', bearer: secret)).status,
          HttpStatus.ok);
      expect((await remove('foreign', 'other@b.c', bearer: secret)).status,
          HttpStatus.ok);
      expect((await package('foreign'))!['uploaders'], ['new@b.c']);
    });

    test('an admin can give a package without uploaders its first', () async {
      final admin = await user('a@b.c', Role.admin);
      await addPackage('legacy', null);
      expect(
          (await add('legacy', 'new@b.c', bearer: await token(admin))).status,
          HttpStatus.ok);
      expect((await package('legacy'))!['uploaders'], ['new@b.c']);
    });

    test('an admin is told when the package does not exist', () async {
      final admin = await user('a@b.c', Role.admin);
      expect(
          (await add('missing', 'new@b.c', bearer: await token(admin))).status,
          HttpStatus.notFound);
    });

    test('a read-scoped token cannot manage uploaders', () async {
      final admin = await user('a@b.c', Role.admin);
      await addPackage('foreign', ['other@b.c']);
      final reply = await add('foreign', 'new@b.c',
          bearer: await token(admin, scopes: {Scope.read}));
      expect(reply.status, HttpStatus.forbidden);
      expect(reply.errorCode, 'insufficient_scope');
    });

    test('an invalid email is rejected', () async {
      final admin = await user('a@b.c', Role.admin);
      await addPackage('foreign', ['other@b.c']);
      expect((await add('foreign', 'no-at', bearer: await token(admin))).status,
          HttpStatus.badRequest);
    });
  });

  group('read gate', () {
    late App private;

    setUp(() {
      private = buildApp(readAccess: ReadAccess.authenticated);
    });

    Future<int> read({String? bearer, Browser? browser, App? using}) async =>
        (await send('GET', '/webapi/packages',
                bearer: bearer, browser: browser, using: using))
            .status;

    test('public mode serves anonymous clients', () async {
      expect(await read(), HttpStatus.ok);
    });

    test('public mode tolerates a stale token', () async {
      expect(await read(bearer: 'stale'), HttpStatus.ok);
    });

    test('public mode accepts a user token', () async {
      final reader = await user('r@b.c', Role.reader);
      expect(await read(bearer: await token(reader)), HttpStatus.ok);
    });

    test('public mode accepts a session', () async {
      final browser = await login(await user('r@b.c', Role.reader));
      expect(await read(browser: browser), HttpStatus.ok);
    });

    test('authenticated mode refuses anonymous clients', () async {
      expect(await read(using: private), HttpStatus.unauthorized);
    });

    test('authenticated mode accepts a user token', () async {
      final reader = await user('r@b.c', Role.reader);
      expect(await read(bearer: await token(reader), using: private),
          HttpStatus.ok);
    });

    test('authenticated mode accepts a session', () async {
      final browser = await login(await user('r@b.c', Role.reader));
      expect(await read(browser: browser, using: private), HttpStatus.ok);
    });

    test('authenticated mode refuses a publish-only token', () async {
      final publisher = await user('p@b.c', Role.publisher);
      final secret = await token(publisher, scopes: {Scope.publish});
      final reply =
          await send('GET', '/webapi/packages', bearer: secret, using: private);
      expect(reply.status, HttpStatus.forbidden);
      expect(reply.errorCode, 'insufficient_scope');
    });

    test('login stays open in authenticated mode', () async {
      final reader = await user('r@b.c', Role.reader);
      await login(reader, using: private);
    });

    test('probes stay open in authenticated mode', () async {
      expect((await send('GET', '/healthz', using: private)).status,
          HttpStatus.ok);
    });

    test('a probe with a trailing slash reaches the router', () async {
      // The router has no such route, but must be the one to say so.
      expect((await send('GET', '/healthz/', using: private)).status,
          HttpStatus.notFound);
    });
  });

  group('token validity', () {
    Future<Reply> me(String secret) =>
        send('GET', '/webapi/me', bearer: secret);

    test('a valid token authenticates and reports its scopes', () async {
      final reader = await user('r@b.c', Role.reader);
      final reply = await me(await token(reader));
      expect(reply.status, HttpStatus.ok);
      expect(reply.body['user']['email'], 'r@b.c');
      expect(reply.body['scopes'], ['read']);
      expect(reply.body.containsKey('csrfToken'), isFalse);
    });

    test('an expired token is anonymous', () async {
      final reader = await user('r@b.c', Role.reader);
      final created = await accounts.createToken(reader, name: 'old');
      await db.collection(tokenCollection).updateOne(
          where.eq('hash', created.token.hash),
          modify.set('expiresAt',
              DateTime.now().subtract(const Duration(seconds: 1))));
      expect((await me(created.secret)).status, HttpStatus.unauthorized);
    });

    test('a revoked token is anonymous', () async {
      final reader = await user('r@b.c', Role.reader);
      final created = await accounts.createToken(reader, name: 'old');
      await accounts.revokeToken(created.token);
      expect((await me(created.secret)).status, HttpStatus.unauthorized);
    });

    test('a token of a disabled user is anonymous', () async {
      final publisher = await user('p@b.c', Role.publisher);
      final secret = await token(publisher);
      await store.updateUser(publisher.id, DateTime.now(), disabled: true);
      expect((await me(secret)).status, HttpStatus.unauthorized);
    });

    test('demoting a user takes effect on existing tokens', () async {
      final publisher = await user('p@b.c', Role.publisher);
      final secret = await token(publisher);
      await store.updateUser(publisher.id, DateTime.now(), role: Role.reader);
      expect(await uploadStatus('fresh', bearer: secret), HttpStatus.forbidden);
    });

    test('lastUsedAt is written at most once a minute', () async {
      final reader = await user('r@b.c', Role.reader);
      final created = await accounts.createToken(reader, name: 'used');
      Future<DateTime?> lastUsed() async =>
          (await store.findTokenById(created.token.id))!.lastUsedAt;

      expect(await lastUsed(), isNull);
      await me(created.secret);
      final first = await lastUsed();
      expect(first, isNotNull);

      await Future<void>.delayed(const Duration(milliseconds: 10));
      await me(created.secret);
      expect(await lastUsed(), first);

      final old = DateTime.now().subtract(const Duration(minutes: 2));
      await db.collection(tokenCollection).updateOne(
          where.eq('hash', created.token.hash), modify.set('lastUsedAt', old));
      await me(created.secret);
      expect((await lastUsed())!.isAfter(old), isTrue);
    });

    test('expiry is enforced with the injected clock', () async {
      final reader = await user('r@b.c', Role.reader);
      final created = await accounts.createToken(reader,
          name: 'short',
          expiresAt: DateTime.now().add(const Duration(hours: 1)));
      final later = ApiTokenAuthenticator(store,
          clock: () => DateTime.now().add(const Duration(hours: 2)));
      expect(
          await later.authenticate(shelf.Request('GET', Uri.parse('http://x/'),
              headers: {'authorization': 'Bearer ${created.secret}'})),
          isNull);
    });
  });

  group('scope narrowing', () {
    test('a read token of a publisher cannot publish', () async {
      final publisher = await user('p@b.c', Role.publisher);
      final secret = await token(publisher, scopes: {Scope.read});
      expect(await uploadStatus('fresh', bearer: secret), HttpStatus.forbidden);
    });

    test('a publish-only token can publish', () async {
      final publisher = await user('p@b.c', Role.publisher);
      final secret = await token(publisher, scopes: {Scope.publish});
      expect(await publish('fresh', '1.0.0', bearer: secret), isNull);
    });

    test('a read token of an admin cannot change users', () async {
      final admin = await user('a@b.c', Role.admin);
      final secret = await token(admin, scopes: {Scope.read});
      final reply = await send('POST', '/webapi/users',
          bearer: secret, body: {'email': 'x@b.c', 'role': 'reader'});
      expect(reply.status, HttpStatus.forbidden);
      expect(reply.errorCode, 'insufficient_scope');
    });

    test('a read token of an admin can list users', () async {
      final admin = await user('a@b.c', Role.admin);
      expect(
          (await send('GET', '/webapi/users',
                  bearer: await token(admin, scopes: {Scope.read})))
              .status,
          HttpStatus.ok);
    });

    test('a publish-only token of an admin cannot list users', () async {
      final admin = await user('a@b.c', Role.admin);
      expect(
          (await send('GET', '/webapi/users',
                  bearer: await token(admin, scopes: {Scope.publish})))
              .status,
          HttpStatus.forbidden);
    });

    test('a token cannot create a token with more scopes', () async {
      final publisher = await user('p@b.c', Role.publisher);
      final secret = await token(publisher, scopes: {Scope.publish});
      final reply = await send('POST', '/webapi/tokens', bearer: secret, body: {
        'name': 'wider',
        'scopes': ['read', 'publish'],
      });
      expect(reply.status, HttpStatus.forbidden);
    });

    test('a token cannot outlive the token creating it', () async {
      final publisher = await user('p@b.c', Role.publisher);
      final short = await accounts.createToken(publisher,
          name: 'short',
          expiresAt: DateTime.now().add(const Duration(days: 1)));
      final tooLong = await send('POST', '/webapi/tokens',
          bearer: short.secret, body: {'name': 'long', 'expiresIn': '30d'});
      expect(tooLong.status, HttpStatus.badRequest);

      final inherited = await send('POST', '/webapi/tokens',
          bearer: short.secret, body: {'name': 'inherits'});
      expect(inherited.status, HttpStatus.created);
      expect(inherited.body['token']['expiresAt'], isNotNull);
    });

    test('a reader cannot get a publish token', () async {
      final browser = await login(await user('r@b.c', Role.reader));
      final reply =
          await send('POST', '/webapi/tokens', browser: browser, body: {
        'name': 'x',
        'scopes': ['publish'],
      });
      expect(reply.status, HttpStatus.forbidden);
    });
  });

  group('legacy static tokens', () {
    late App legacy;

    setUp(() {
      legacy = buildApp(
        readAccess: ReadAccess.authenticated,
        bootstrapToken: 'bootstrap-secret',
        readTokens: {'reader-secret'},
      );
      app = legacy;
    });

    test('the bootstrap token is an admin', () async {
      await addPackage('foreign', ['other@b.c']);
      expect(await publish('foreign', '1.0.0', bearer: 'bootstrap-secret'),
          isNull);
      final versions = (await package('foreign'))!['versions'] as List;
      expect(versions.last['uploader'], 'ops@example.com');
    });

    test('the bootstrap token can list users', () async {
      expect(
          (await send('GET', '/webapi/users', bearer: 'bootstrap-secret'))
              .status,
          HttpStatus.ok);
    });

    test('me reports a static identity without an account', () async {
      final reply = await send('GET', '/webapi/me', bearer: 'bootstrap-secret');
      expect(reply.body['user']['id'], isNull);
      expect(reply.body['user']['email'], 'ops@example.com');
      expect(reply.body['user']['role'], 'admin');
    });

    test('a static identity cannot have personal tokens', () async {
      final reply = await send('POST', '/webapi/tokens',
          bearer: 'bootstrap-secret', body: {'name': 'x'});
      expect(reply.status, HttpStatus.forbidden);
    });

    test('a read token can read', () async {
      expect(
          (await send('GET', '/webapi/packages', bearer: 'reader-secret'))
              .status,
          HttpStatus.ok);
    });

    test('a read token cannot publish', () async {
      expect(await uploadStatus('fresh', bearer: 'reader-secret'),
          HttpStatus.forbidden);
    });

    test('a user token wins over a static token of the same value', () async {
      final reader = await user('r@b.c', Role.reader);
      final secret = await token(reader);
      final both = buildApp(bootstrapToken: secret);
      final reply =
          await send('GET', '/webapi/me', bearer: secret, using: both);
      expect(reply.body['user']['email'], 'r@b.c');
    });
  });

  group('csrf', () {
    late User publisher;
    late Browser browser;

    setUp(() async {
      publisher = await user('p@b.c', Role.publisher);
      browser = await login(publisher);
      await addPackage('owned', ['p@b.c']);
    });

    Future<Reply> createToken({required bool csrf, Browser? using}) =>
        send('POST', '/webapi/tokens',
            browser: using ?? browser, sendCsrf: csrf, body: {'name': 'x'});

    test('a session write without the token is refused', () async {
      final reply = await createToken(csrf: false);
      expect(reply.status, HttpStatus.forbidden);
      expect(reply.errorCode, 'csrf_failed');
    });

    test('a session write with a wrong token is refused', () async {
      final reply = await send('POST', '/webapi/tokens',
          browser: browser,
          sendCsrf: false,
          headers: {'x-csrf-token': 'wrong'},
          body: {'name': 'x'});
      expect(reply.status, HttpStatus.forbidden);
    });

    test('a session write with the header passes', () async {
      expect((await createToken(csrf: true)).status, HttpStatus.created);
    });

    test('a form write with the field passes and keeps its body', () async {
      final reply = await send('POST', '/api/packages/owned/uploaders',
          browser: browser,
          sendCsrf: false,
          form: 'email=new%40b.c&csrf_token=${browser.csrf}');
      expect(reply.status, HttpStatus.ok, reason: '${reply.body}');
      expect((await package('owned'))!['uploaders'], ['p@b.c', 'new@b.c']);
    });

    test('a form write with a wrong field is refused', () async {
      final reply = await send('POST', '/api/packages/owned/uploaders',
          browser: browser,
          sendCsrf: false,
          form: 'email=new%40b.c&csrf_token=wrong');
      expect(reply.status, HttpStatus.forbidden);
      expect((await package('owned'))!['uploaders'], ['p@b.c']);
    });

    test('the token of another session is refused', () async {
      final other = await login(await user('o@b.c', Role.publisher));
      final reply = await send('POST', '/webapi/tokens',
          browser: browser,
          sendCsrf: false,
          headers: {'x-csrf-token': other.csrf},
          body: {'name': 'x'});
      expect(reply.status, HttpStatus.forbidden);
    });

    test('safe methods do not need the token', () async {
      expect(
          (await send('GET', '/webapi/tokens',
                  browser: browser, sendCsrf: false))
              .status,
          HttpStatus.ok);
    });

    test('a Bearer token does not need it', () async {
      expect(
          (await send('POST', '/webapi/tokens',
                  bearer: await token(publisher), body: {'name': 'x'}))
              .status,
          HttpStatus.created);
    });

    test('a stale cookie does not prevent logging in', () async {
      final reply = await send('POST', '/webapi/login',
          headers: {'cookie': '$sessionCookieName=stale'},
          body: {'email': 'p@b.c', 'password': _password});
      expect(reply.status, HttpStatus.ok);
    });

    test('me returns the token of the session', () async {
      final reply = await send('GET', '/webapi/me', browser: browser);
      expect(reply.body['csrfToken'], browser.csrf);
    });
  });

  group('sessions', () {
    test('login sets a protected cookie and returns the user', () async {
      await user('r@b.c', Role.reader);
      final reply = await send('POST', '/webapi/login',
          body: {'email': 'R@B.C', 'password': _password});
      expect(reply.status, HttpStatus.ok);
      expect(reply.body['user']['email'], 'r@b.c');
      expect(reply.body['user'].containsKey('passwordHash'), isFalse);
      expect(reply.body['csrfToken'], isA<String>());
      final cookie = reply.headers['set-cookie']!;
      expect(cookie, startsWith('$sessionCookieName='));
      expect(cookie, contains('HttpOnly'));
      expect(cookie, contains('SameSite=Lax'));
      expect(cookie, contains('Path=/'));
      expect(cookie, isNot(contains('Secure')));
      expect(reply.headers['cache-control'], 'no-store');
    });

    test('the cookie is Secure when the server is public over https', () async {
      await user('r@b.c', Role.reader);
      final reply = await send('POST', '/webapi/login',
          body: {'email': 'r@b.c', 'password': _password},
          using: buildApp(secureCookies: true));
      expect(reply.headers['set-cookie'], contains('Secure'));
    });

    test('the session is stored under the hash of the cookie', () async {
      final browser = await login(await user('r@b.c', Role.reader));
      final session = (await db.collection(sessionCollection).findOne())!;
      expect(session['_id'], hashSecret(browser.cookie));
      expect(session['_id'], isNot(browser.cookie));
      expect(session['csrfToken'], browser.csrf);
      expect(
          (session['expiresAt'] as DateTime).isAfter(DateTime.now()), isTrue);
    });

    test('login records the time', () async {
      final reader = await user('r@b.c', Role.reader);
      expect(reader.lastLoginAt, isNull);
      await login(reader);
      expect((await store.findUserById(reader.id))!.lastLoginAt, isNotNull);
    });

    test('the login response carries the new login time', () async {
      final reader = await user('r@b.c', Role.reader);
      final reply = await send('POST', '/webapi/login',
          body: {'email': 'r@b.c', 'password': _password});
      final stored = (await store.findUserById(reader.id))!.lastLoginAt!;
      expect(
          reply.body['user']['lastLoginAt'], stored.toUtc().toIso8601String());
    });

    for (final failure in ['bad password', 'unknown user']) {
      test('a failed login is the same for $failure', () async {
        await user('r@b.c', Role.reader);
        final reply = await send('POST', '/webapi/login', body: {
          'email': failure == 'bad password' ? 'r@b.c' : 'x@b.c',
          'password': 'wrong-password',
        });
        expect(reply.status, HttpStatus.unauthorized);
        expect(reply.errorCode, 'invalid_credentials');
        expect(reply.body['error']['message'], 'Invalid email or password.');
        expect(reply.headers.containsKey('set-cookie'), isFalse);
      });
    }

    test('a placeholder cannot log in', () async {
      await user('p@b.c', Role.publisher, password: null);
      final reply = await send('POST', '/webapi/login',
          body: {'email': 'p@b.c', 'password': 'anything-long'});
      expect(reply.status, HttpStatus.unauthorized);
    });

    test('a disabled user cannot log in', () async {
      final reader = await user('r@b.c', Role.reader);
      await store.updateUser(reader.id, DateTime.now(), disabled: true);
      final reply = await send('POST', '/webapi/login',
          body: {'email': 'r@b.c', 'password': _password});
      expect(reply.status, HttpStatus.unauthorized);
    });

    for (final body in <Map<String, Object?>>[
      {'email': 'a@b.c'},
      {'password': 'x'},
      {'email': 1, 'password': 2},
      {'email': 'no-at', 'password': 'x'},
    ]) {
      test('login rejects $body', () async {
        final reply = await send('POST', '/webapi/login', body: body);
        expect(reply.status, HttpStatus.badRequest);
        expect(reply.errorCode, 'invalid_request');
      });
    }

    test('login rejects a form post', () async {
      final reply =
          await send('POST', '/webapi/login', form: 'email=a@b.c&password=x');
      expect(reply.status, HttpStatus.badRequest);
    });

    test('login rejects a body that is not JSON', () async {
      final reply = await send('POST', '/webapi/login',
          headers: {'content-type': 'application/json'}, form: 'not json');
      expect(reply.status, HttpStatus.badRequest);
    });

    test('an expired session is anonymous', () async {
      final browser = await login(await user('r@b.c', Role.reader));
      await db.collection(sessionCollection).updateOne(
          where.eq('_id', hashSecret(browser.cookie)),
          modify.set('expiresAt',
              DateTime.now().subtract(const Duration(seconds: 1))));
      expect((await send('GET', '/webapi/me', browser: browser)).status,
          HttpStatus.unauthorized);
    });

    test('a session of a disabled user is anonymous', () async {
      final reader = await user('r@b.c', Role.reader);
      final browser = await login(reader);
      await store.updateUser(reader.id, DateTime.now(), disabled: true);
      expect((await send('GET', '/webapi/me', browser: browser)).status,
          HttpStatus.unauthorized);
    });

    test('logout ends the session and clears the cookie', () async {
      final browser = await login(await user('r@b.c', Role.reader));
      final reply = await send('POST', '/webapi/logout', browser: browser);
      expect(reply.status, HttpStatus.ok);
      expect(reply.headers['set-cookie'], contains('Max-Age=0'));
      expect((await send('GET', '/webapi/me', browser: browser)).status,
          HttpStatus.unauthorized);
    });

    test('logout needs the CSRF token', () async {
      final browser = await login(await user('r@b.c', Role.reader));
      final reply = await send('POST', '/webapi/logout',
          browser: browser, sendCsrf: false);
      expect(reply.status, HttpStatus.forbidden);
    });

    test('a new login replaces the previous session of the browser', () async {
      final reader = await user('r@b.c', Role.reader);
      final first = await login(reader);
      await send('POST', '/webapi/login',
          headers: {'cookie': '$sessionCookieName=${first.cookie}'},
          body: {'email': 'r@b.c', 'password': _password});
      expect((await send('GET', '/webapi/me', browser: first)).status,
          HttpStatus.unauthorized);
    });

    for (final (role, scopes) in [
      (Role.reader, ['read']),
      (Role.publisher, ['read', 'publish']),
      (Role.admin, ['read', 'publish']),
    ]) {
      test('a session of a ${role.name} holds $scopes', () async {
        final browser = await login(await user('u@b.c', role));
        final reply = await send('GET', '/webapi/me', browser: browser);
        expect(reply.body['scopes'], unorderedEquals(scopes));
      });
    }

    test('a reader session is refused a publish route by the middleware',
        () async {
      final browser = await login(await user('r@b.c', Role.reader));
      await addPackage('owned', ['r@b.c']);
      final reply = await send('POST', '/api/packages/owned/uploaders',
          browser: browser, form: 'email=new%40b.c');
      expect(reply.status, HttpStatus.forbidden);
      // The handler would have answered with a plain error, not this code.
      expect(reply.errorCode, 'insufficient_scope');
      expect((await package('owned'))!['uploaders'], ['r@b.c']);
    });

    test('a reader can still look after their own account', () async {
      final browser = await login(await user('r@b.c', Role.reader));

      final created = await send('POST', '/webapi/tokens',
          browser: browser, body: {'name': 'laptop'});
      expect(created.status, HttpStatus.created);
      expect(created.body['token']['scopes'], ['read']);

      final id = created.body['token']['id'];
      expect(
          (await send('DELETE', '/webapi/tokens/$id', browser: browser)).status,
          HttpStatus.ok);

      expect(
          (await send('POST', '/webapi/me/password', browser: browser, body: {
            'currentPassword': _password,
            'newPassword': 'a-new-password',
          }))
              .status,
          HttpStatus.ok);

      expect((await send('POST', '/webapi/logout', browser: browser)).status,
          HttpStatus.ok);
    });

    test('me without credentials is unauthorized in public mode', () async {
      final reply = await send('GET', '/webapi/me');
      expect(reply.status, HttpStatus.unauthorized);
      expect(reply.errorCode, 'unauthorized');
    });
  });

  group('rate limit', () {
    late App limited;

    setUp(() async {
      limited = buildApp(limiter: LoginRateLimiter(maxFailures: 3));
      await user('r@b.c', Role.reader);
    });

    Future<Reply> attempt(String email, String password, String ip) =>
        send('POST', '/webapi/login',
            body: {'email': email, 'password': password},
            headers: {'x-forwarded-for': ip},
            using: limited);

    test('too many failures for one email give 429', () async {
      for (var i = 0; i < 3; i++) {
        expect((await attempt('r@b.c', 'wrong-pass', '10.0.0.$i')).status,
            HttpStatus.unauthorized);
      }
      final blocked = await attempt('r@b.c', _password, '10.0.1.1');
      expect(blocked.status, HttpStatus.tooManyRequests);
      expect(blocked.errorCode, 'rate_limited');
      expect(int.parse(blocked.headers['retry-after']!), greaterThan(0));
    });

    test('too many failures from one address give 429', () async {
      for (var i = 0; i < 3; i++) {
        await attempt('user$i@b.c', 'wrong-pass', '10.0.0.1');
      }
      expect((await attempt('r@b.c', _password, '10.0.0.1')).status,
          HttpStatus.tooManyRequests);
      expect((await attempt('r@b.c', _password, '10.0.0.2')).status,
          HttpStatus.ok);
    });

    test('only the last forwarded address counts', () async {
      for (var i = 0; i < 3; i++) {
        await attempt('user$i@b.c', 'wrong-pass', 'spoofed$i, 10.0.0.1');
      }
      expect((await attempt('r@b.c', _password, 'other, 10.0.0.1')).status,
          HttpStatus.tooManyRequests);
    });

    test('parallel guesses cannot exceed the limit', () async {
      final results = await Future.wait([
        for (var i = 0; i < 10; i++)
          attempt('r@b.c', 'wrong-pass-$i', '10.0.0.$i'),
      ]);
      expect(results.where((r) => r.status == HttpStatus.unauthorized),
          hasLength(3));
      expect(results.where((r) => r.status == HttpStatus.tooManyRequests),
          hasLength(7));
    });

    test('a success resets the failures of the email', () async {
      await attempt('r@b.c', 'wrong-pass', '10.0.0.1');
      await attempt('r@b.c', 'wrong-pass', '10.0.0.2');
      expect((await attempt('r@b.c', _password, '10.0.0.3')).status,
          HttpStatus.ok);
      await attempt('r@b.c', 'wrong-pass', '10.0.0.4');
      await attempt('r@b.c', 'wrong-pass', '10.0.0.5');
      expect((await attempt('r@b.c', _password, '10.0.0.6')).status,
          HttpStatus.ok);
    });

    test('a limiter with no room left answers 429', () async {
      final full =
          buildApp(limiter: LoginRateLimiter(maxFailures: 1, maxKeys: 2));
      Future<Reply> attemptOn(String ip) => send('POST', '/webapi/login',
          body: {'email': 'r@b.c', 'password': 'wrong-pass'},
          headers: {'x-forwarded-for': ip},
          using: full);

      expect((await attemptOn('10.0.0.1')).status, HttpStatus.unauthorized);
      final refused = await attemptOn('10.0.0.2');
      expect(refused.status, HttpStatus.tooManyRequests);
      expect(refused.errorCode, 'rate_limited');
      expect(refused.headers['retry-after'], isNotNull);
    });

    test('a malformed request does not use up attempts', () async {
      for (var i = 0; i < 5; i++) {
        expect(
            (await send('POST', '/webapi/login',
                    body: {'email': 'r@b.c'}, using: limited))
                .status,
            HttpStatus.badRequest);
      }
      expect((await attempt('r@b.c', _password, '10.0.0.1')).status,
          HttpStatus.ok);
    });

    test('wrong current passwords are limited too', () async {
      final publisher = await user('p@b.c', Role.publisher);
      final browser = await login(publisher, using: limited);
      Future<Reply> change() => send('POST', '/webapi/me/password',
              browser: browser,
              using: limited,
              body: {
                'currentPassword': 'wrong-password',
                'newPassword': 'a-new-password',
              });
      for (var i = 0; i < 3; i++) {
        expect((await change()).status, HttpStatus.forbidden);
      }
      expect((await change()).status, HttpStatus.tooManyRequests);
    });
  });

  group('own tokens', () {
    late User owner;
    late Browser browser;

    setUp(() async {
      owner = await user('p@b.c', Role.publisher);
      browser = await login(owner);
    });

    test('create returns the secret once and stores only its hash', () async {
      final reply =
          await send('POST', '/webapi/tokens', browser: browser, body: {
        'name': ' laptop ',
        'scopes': ['read'],
        'expiresIn': '30d',
      });
      expect(reply.status, HttpStatus.created);
      final secret = reply.body['secret'] as String;
      expect(base64Url.decode(base64.normalize(secret)), hasLength(32));

      final json = reply.body['token'] as Map;
      expect(json['name'], 'laptop');
      expect(json['prefix'], secret.substring(0, 8));
      expect(json['scopes'], ['read']);
      expect(json['expiresAt'], isNotNull);
      expect(json.containsKey('hash'), isFalse);

      final stored = (await db.collection(tokenCollection).findOne())!;
      expect(stored['hash'], hashSecret(secret));
      expect(stored.values, isNot(contains(secret)));

      final list = await send('GET', '/webapi/tokens', browser: browser);
      expect(list.body['tokens'], hasLength(1));
      expect(list.body['tokens'][0].containsKey('hash'), isFalse);
      expect(jsonEncode(list.body), isNot(contains(secret)));
    });

    test('defaults to the scopes the role allows', () async {
      final reply = await send('POST', '/webapi/tokens',
          browser: browser, body: {'name': 'x'});
      expect(
          reply.body['token']['scopes'], unorderedEquals(['read', 'publish']));
    });

    for (final body in <Map<String, Object?>>[
      {},
      {'name': ''},
      {'name': 'x', 'scopes': 'read'},
      {
        'name': 'x',
        'scopes': ['write'],
      },
      {'name': 'x', 'scopes': <String>[]},
      {'name': 'x', 'expiresIn': 'soon'},
      {'name': 'x' * 101},
    ]) {
      test('create rejects $body', () async {
        final reply =
            await send('POST', '/webapi/tokens', browser: browser, body: body);
        expect(reply.status, HttpStatus.badRequest, reason: '${reply.body}');
      });
    }

    test('lists only the tokens of the caller', () async {
      final other = await user('o@b.c', Role.publisher);
      await token(other);
      await token(owner);
      final list = await send('GET', '/webapi/tokens', browser: browser);
      expect(list.body['tokens'], hasLength(1));
    });

    test('can revoke an own token, repeatedly', () async {
      final created = await accounts.createToken(owner, name: 'x');
      final route = '/webapi/tokens/${created.token.id}';
      final reply = await send('DELETE', route, browser: browser);
      expect(reply.status, HttpStatus.ok);
      expect(reply.body['token']['revokedAt'], isNotNull);

      expect((await send('DELETE', route, browser: browser)).status,
          HttpStatus.ok);
      expect(await auditEvents('token.revoked'), hasLength(1));
    });

    test('someone else\'s token looks absent', () async {
      final other = await user('o@b.c', Role.publisher);
      final created = await accounts.createToken(other, name: 'x');
      final reply = await send('DELETE', '/webapi/tokens/${created.token.id}',
          browser: browser);
      expect(reply.status, HttpStatus.notFound);
      expect((await store.findTokenById(created.token.id))!.revokedAt, isNull);
    });

    test('an admin can revoke any token', () async {
      final admin = await login(await user('a@b.c', Role.admin));
      final created = await accounts.createToken(owner, name: 'x');
      expect(
          (await send('DELETE', '/webapi/tokens/${created.token.id}',
                  browser: admin))
              .status,
          HttpStatus.ok);
    });

    group('revoking the token of another user', () {
      Future<Reply> revoke(ApiToken target,
              {String? bearer, Browser? browser, App? using}) =>
          send('DELETE', '/webapi/tokens/${target.id}',
              bearer: bearer, browser: browser, using: using);

      Future<void> expectStillActive(ApiToken target) async =>
          expect((await store.findTokenById(target.id))!.revokedAt, isNull);

      Future<Map<String, dynamic>> revocationAudit() async {
        final events = await auditEvents('token.revoked');
        expect(events, hasLength(1));
        return events.single;
      }

      test('needs a password login for an admin API token', () async {
        final admin = await user('a@b.c', Role.admin);
        final target = (await accounts.createToken(owner, name: 'x')).token;
        final reply = await revoke(target,
            bearer: await token(admin, scopes: {Scope.publish}));
        expect(reply.status, HttpStatus.forbidden);
        expect(reply.errorCode, 'session_required');
        await expectStillActive(target);
        expect(await auditEvents('token.revoked'), isEmpty);
      });

      test('needs a password login for the bootstrap token', () async {
        final target = (await accounts.createToken(owner, name: 'x')).token;
        final reply = await revoke(target,
            bearer: 'legacy', using: buildApp(bootstrapToken: 'legacy'));
        expect(reply.status, HttpStatus.forbidden);
        expect(reply.errorCode, 'session_required');
        await expectStillActive(target);
      });

      test('works for an admin with a password login, and says so', () async {
        final admin = await user('a@b.c', Role.admin);
        final target = (await accounts.createToken(owner, name: 'x')).token;
        final reply = await revoke(target, browser: await login(admin));
        expect(reply.status, HttpStatus.ok);
        expect((await store.findTokenById(target.id))!.revokedAt, isNotNull);

        final event = await revocationAudit();
        expect(event['actor'], admin.email);
        expect(event['details']['actorKind'], 'session');
        expect(event['details']['ownerId'], owner.id);
      });

      test('looks absent to a token of someone who is not an admin', () async {
        final other = await user('o@b.c', Role.publisher);
        final target = (await accounts.createToken(other, name: 'x')).token;
        final reply = await revoke(target,
            bearer: await token(owner, scopes: {Scope.publish}));
        expect(reply.status, HttpStatus.notFound);
        expect(reply.errorCode, 'not_found');
        await expectStillActive(target);
      });

      test('an API token can still revoke a token of its own user', () async {
        final admin = await user('a@b.c', Role.admin);
        final target = (await accounts.createToken(admin, name: 'x')).token;
        final reply = await revoke(target,
            bearer: await token(admin, scopes: {Scope.publish}));
        expect(reply.status, HttpStatus.ok);

        final event = await revocationAudit();
        expect(event['details']['actorKind'], 'apiToken');
      });
    });

    test('a malformed or unknown id is a 404', () async {
      for (final id in ['nope', '0123456789abcdef01234567']) {
        expect(
            (await send('DELETE', '/webapi/tokens/$id', browser: browser))
                .status,
            HttpStatus.notFound);
      }
    });
  });

  group('own password', () {
    late User owner;
    late Browser browser;

    setUp(() async {
      owner = await user('p@b.c', Role.publisher);
      browser = await login(owner);
    });

    Future<Reply> change(String current, String replacement) =>
        send('POST', '/webapi/me/password', browser: browser, body: {
          'currentPassword': current,
          'newPassword': replacement,
        });

    test('needs the current password', () async {
      final reply = await change('wrong-password', 'a-new-password');
      expect(reply.status, HttpStatus.forbidden);
      expect(reply.errorCode, 'invalid_credentials');
    });

    test('enforces the password rules', () async {
      expect((await change(_password, 'short')).status, HttpStatus.badRequest);
    });

    test('changes the password and ends other sessions only', () async {
      final other = await login(owner);
      expect((await change(_password, 'a-new-password')).status, HttpStatus.ok);

      expect((await send('GET', '/webapi/me', browser: browser)).status,
          HttpStatus.ok);
      expect((await send('GET', '/webapi/me', browser: other)).status,
          HttpStatus.unauthorized);

      expect(
          (await send('POST', '/webapi/login',
                  body: {'email': 'p@b.c', 'password': _password}))
              .status,
          HttpStatus.unauthorized);
      expect(
          (await send('POST', '/webapi/login',
                  body: {'email': 'p@b.c', 'password': 'a-new-password'}))
              .status,
          HttpStatus.ok);
    });

    test('an account without a password has no current password to give',
        () async {
      await db.collection(userCollection).updateOne(
          where.eq('email', 'p@b.c'), modify.set('passwordHash', null));
      final reply = await change('anything-long', 'a-new-password');
      expect(reply.status, HttpStatus.forbidden);
      expect(reply.errorCode, 'invalid_credentials');
    });
  });

  group('credential management needs a password login', () {
    const stolenPassword = 'chosen-by-the-attacker';

    void expectSessionRequired(Reply reply) {
      expect(reply.status, HttpStatus.forbidden, reason: '${reply.body}');
      expect(reply.errorCode, 'session_required');
    }

    Future<int> loginStatus(String email, String password) async =>
        (await send('POST', '/webapi/login',
                body: {'email': email, 'password': password}))
            .status;

    test('a narrowed, expiring admin token cannot trade itself for more',
        () async {
      final admin = await user('a@b.c', Role.admin);
      final limited = await accounts.createToken(admin,
          name: 'ci',
          scopes: {Scope.publish},
          expiresAt: DateTime.now().add(const Duration(minutes: 1)));
      final secret = limited.secret;

      expect((await send('GET', '/webapi/users', bearer: secret)).status,
          HttpStatus.forbidden);
      expectSessionRequired(await send(
          'POST', '/webapi/users/${admin.id}/password',
          bearer: secret, body: {'password': stolenPassword}));
      expectSessionRequired(await send('POST', '/webapi/me/password',
          bearer: secret,
          body: {'currentPassword': _password, 'newPassword': stolenPassword}));

      expect(
          await loginStatus('a@b.c', stolenPassword), HttpStatus.unauthorized);
      expect((await store.findUserById(admin.id))!.passwordHash,
          admin.passwordHash);

      // The token keeps what it has, and no more.
      final wider = await send('POST', '/webapi/tokens', bearer: secret, body: {
        'name': 'wider',
        'scopes': ['read', 'publish'],
      });
      expect(wider.status, HttpStatus.forbidden);
      final longer = await send('POST', '/webapi/tokens',
          bearer: secret, body: {'name': 'longer', 'expiresIn': '30d'});
      expect(longer.status, HttpStatus.badRequest);
      final narrow = await send('POST', '/webapi/tokens',
          bearer: secret, body: {'name': 'narrow'});
      expect(narrow.status, HttpStatus.created);
      expect(narrow.body['token']['scopes'], ['publish']);
      expect(narrow.body['token']['expiresAt'], isNotNull);
    });

    for (final (name, scopes) in [
      ('a full', allScopes),
      ('a publish-only', const {Scope.publish}),
    ]) {
      test('$name admin token cannot create a user', () async {
        final admin = await user('a@b.c', Role.admin);
        final reply = await send('POST', '/webapi/users',
            bearer: await token(admin, scopes: scopes),
            body: {
              'email': 'new@b.c',
              'role': 'admin',
              'password': stolenPassword,
            });
        expectSessionRequired(reply);
        expect(await store.findUserByEmail('new@b.c'), isNull);
      });
    }

    test('an admin token cannot change a role or the disabled state', () async {
      final admin = await user('a@b.c', Role.admin);
      final other = await user('o@b.c', Role.reader);
      final secret = await token(admin);
      for (final body in <Map<String, Object?>>[
        {'role': 'admin'},
        {'disabled': true},
      ]) {
        expectSessionRequired(await send('PATCH', '/webapi/users/${other.id}',
            bearer: secret, body: body));
      }
      final unchanged = (await store.findUserById(other.id))!;
      expect(unchanged.role, Role.reader);
      expect(unchanged.disabled, isFalse);
    });

    test('the bootstrap token is refused as well', () async {
      final bootstrap = buildApp(bootstrapToken: 'bootstrap-secret');
      final target = await user('o@b.c', Role.reader);
      Future<Reply> asBootstrap(
              String method, String route, Map<String, Object?> body) =>
          send(method, route,
              bearer: 'bootstrap-secret', body: body, using: bootstrap);

      expectSessionRequired(await asBootstrap(
          'POST', '/webapi/users', {'email': 'new@b.c', 'role': 'admin'}));
      expectSessionRequired(await asBootstrap(
          'PATCH', '/webapi/users/${target.id}', {'role': 'admin'}));
      expectSessionRequired(await asBootstrap('POST',
          '/webapi/users/${target.id}/password', {'password': stolenPassword}));
    });

    test('a token sent along with a session cookie counts as the token',
        () async {
      final admin = await user('a@b.c', Role.admin);
      final browser = await login(admin);
      expectSessionRequired(await send('POST', '/webapi/users',
          bearer: await token(admin),
          browser: browser,
          body: {'email': 'new@b.c', 'role': 'reader'}));
    });

    test('a session of a non-admin is refused for lacking the role', () async {
      final publisher = await login(await user('p@b.c', Role.publisher));
      final reply = await send('POST', '/webapi/users',
          browser: publisher, body: {'email': 'new@b.c', 'role': 'reader'});
      expect(reply.status, HttpStatus.forbidden);
      expect(reply.errorCode, 'forbidden');
    });

    test('a token of a non-admin is refused for lacking the role', () async {
      final publisher = await user('p@b.c', Role.publisher);
      final reply = await send('POST', '/webapi/users',
          bearer: await token(publisher),
          body: {'email': 'new@b.c', 'role': 'reader'});
      expect(reply.status, HttpStatus.forbidden);
      expect(reply.errorCode, 'forbidden');
    });

    test('a session can still do all of it', () async {
      final admin = await user('a@b.c', Role.admin);
      final browser = await login(admin);
      final created = await send('POST', '/webapi/users',
          browser: browser, body: {'email': 'new@b.c', 'role': 'reader'});
      expect(created.status, HttpStatus.created);
      final id = created.body['user']['id'];
      expect(
          (await send('PATCH', '/webapi/users/$id',
                  browser: browser, body: {'role': 'publisher'}))
              .status,
          HttpStatus.ok);
      expect(
          (await send('POST', '/webapi/users/$id/password',
                  browser: browser, body: {'password': 'a-new-password'}))
              .status,
          HttpStatus.ok);
      expect(
          (await send('POST', '/webapi/me/password', browser: browser, body: {
            'currentPassword': _password,
            'newPassword': 'a-new-password',
          }))
              .status,
          HttpStatus.ok);
    });
  });

  group('user administration', () {
    late User admin;
    late Browser browser;

    setUp(() async {
      admin = await user('a@b.c', Role.admin);
      browser = await login(admin);
    });

    test('a publisher is refused on every route', () async {
      final publisher = await user('p@b.c', Role.publisher);
      final session = await login(publisher);
      for (final reply in [
        await send('GET', '/webapi/users', browser: session),
        await send('POST', '/webapi/users',
            browser: session, body: {'email': 'x@b.c', 'role': 'reader'}),
        await send('PATCH', '/webapi/users/${publisher.id}',
            browser: session, body: {'role': 'admin'}),
        await send('POST', '/webapi/users/${admin.id}/password',
            browser: session, body: {'password': 'a-new-password'}),
      ]) {
        expect(reply.status, HttpStatus.forbidden);
        expect(reply.errorCode, 'forbidden');
      }
      expect((await store.findUserById(publisher.id))!.role, Role.publisher);
    });

    test('anonymous clients are refused', () async {
      expect(
          (await send('GET', '/webapi/users')).status, HttpStatus.unauthorized);
    });

    test('lists users without their hashes', () async {
      final reply = await send('GET', '/webapi/users', browser: browser);
      expect(reply.body['users'], hasLength(1));
      expect(reply.body['users'][0]['hasPassword'], isTrue);
      expect(jsonEncode(reply.body), isNot(contains('argon2')));
    });

    test('creates a user', () async {
      final reply =
          await send('POST', '/webapi/users', browser: browser, body: {
        'email': 'New@B.c',
        'role': 'publisher',
        'displayName': 'New Person',
        'password': 'a-new-password',
      });
      expect(reply.status, HttpStatus.created);
      expect(reply.body['user']['email'], 'new@b.c');
      expect(reply.body['user']['displayName'], 'New Person');

      expect(
          (await send('POST', '/webapi/login',
                  body: {'email': 'new@b.c', 'password': 'a-new-password'}))
              .status,
          HttpStatus.ok);
    });

    test('creates a placeholder without a password', () async {
      final reply = await send('POST', '/webapi/users',
          browser: browser, body: {'email': 'new@b.c', 'role': 'reader'});
      expect(reply.status, HttpStatus.created);
      expect(reply.body['user']['hasPassword'], isFalse);
      expect(reply.body['user']['displayName'], 'new');
    });

    test('a duplicate email is a conflict', () async {
      final reply = await send('POST', '/webapi/users',
          browser: browser, body: {'email': 'A@b.c', 'role': 'reader'});
      expect(reply.status, HttpStatus.conflict);
      expect(reply.errorCode, 'conflict');
    });

    for (final body in <Map<String, Object?>>[
      {'email': 'x@b.c'},
      {'email': 'no-at', 'role': 'reader'},
      {'email': 'x@b.c', 'role': 'owner'},
      {'email': 'x@b.c', 'role': 'reader', 'password': 'short'},
    ]) {
      test('rejects the new user $body', () async {
        final reply =
            await send('POST', '/webapi/users', browser: browser, body: body);
        expect(reply.status, HttpStatus.badRequest);
      });
    }

    test('patches role, disabled state and name', () async {
      final other = await user('o@b.c', Role.reader);
      final reply = await send('PATCH', '/webapi/users/${other.id}',
          browser: browser,
          body: {
            'role': 'publisher',
            'displayName': 'Other',
            'disabled': true
          });
      expect(reply.status, HttpStatus.ok);
      expect(reply.body['user']['role'], 'publisher');
      expect(reply.body['user']['displayName'], 'Other');
      expect(reply.body['user']['disabled'], isTrue);
    });

    test('disabling a user ends their sessions', () async {
      final other = await user('o@b.c', Role.reader);
      final session = await login(other);
      await send('PATCH', '/webapi/users/${other.id}',
          browser: browser, body: {'disabled': true});
      expect(
          await db
              .collection(sessionCollection)
              .findOne(where.eq('_id', hashSecret(session.cookie))),
          isNull);
    });

    for (final body in <Map<String, Object?>>[
      {'role': 'owner'},
      {'disabled': 'yes'},
      {'displayName': '  '},
      {'displayName': 5},
    ]) {
      test('rejects the patch $body', () async {
        final other = await user('o@b.c', Role.reader);
        final reply = await send('PATCH', '/webapi/users/${other.id}',
            browser: browser, body: body);
        expect(reply.status, HttpStatus.badRequest);
      });
    }

    test('an unknown user is a 404', () async {
      for (final id in ['nope', '0123456789abcdef01234567']) {
        final reply = await send('PATCH', '/webapi/users/$id',
            browser: browser, body: {'role': 'reader'});
        expect(reply.status, HttpStatus.notFound);
        expect(reply.errorCode, 'not_found');
      }
    });

    test('the last admin cannot be demoted or disabled', () async {
      for (final body in <Map<String, Object?>>[
        {'role': 'reader'},
        {'disabled': true},
      ]) {
        final reply = await send('PATCH', '/webapi/users/${admin.id}',
            browser: browser, body: body);
        expect(reply.status, HttpStatus.conflict);
        expect(reply.errorCode, 'last_admin');
      }
      expect((await store.findUserById(admin.id))!.role, Role.admin);
    });

    test('an admin can be demoted while another remains', () async {
      await user('b@b.c', Role.admin);
      final reply = await send('PATCH', '/webapi/users/${admin.id}',
          browser: browser, body: {'role': 'reader'});
      expect(reply.status, HttpStatus.ok);
    });

    test('a disabled admin does not count as remaining', () async {
      final other = await user('b@b.c', Role.admin);
      await store.updateUser(other.id, DateTime.now(), disabled: true);
      final reply = await send('PATCH', '/webapi/users/${admin.id}',
          browser: browser, body: {'role': 'reader'});
      expect(reply.status, HttpStatus.conflict);
    });

    test('an admin can set a password and it ends sessions', () async {
      final other = await user('o@b.c', Role.reader);
      final session = await login(other);
      final reply = await send('POST', '/webapi/users/${other.id}/password',
          browser: browser, body: {'password': 'set-by-admin'});
      expect(reply.status, HttpStatus.ok);
      expect((await send('GET', '/webapi/me', browser: session)).status,
          HttpStatus.unauthorized);
      expect(
          (await send('POST', '/webapi/login',
                  body: {'email': 'o@b.c', 'password': 'set-by-admin'}))
              .status,
          HttpStatus.ok);
    });

    test('a placeholder can log in after a password is set', () async {
      final placeholder = await user('q@b.c', Role.publisher, password: null);
      await send('POST', '/webapi/users/${placeholder.id}/password',
          browser: browser, body: {'password': 'set-by-admin'});
      expect(
          (await send('POST', '/webapi/login',
                  body: {'email': 'q@b.c', 'password': 'set-by-admin'}))
              .status,
          HttpStatus.ok);
    });
  });

  group('last administrator guard', () {
    Future<int> statusOf(Future<User> Function() change) async {
      try {
        await change();
        return HttpStatus.ok;
      } on AccountException catch (error) {
        return error.statusCode;
      }
    }

    Future<Map<String, dynamic>?> adminSet() => db
        .collection(adminSetCollection)
        .findOne(where.eq('_id', 'enabled_admins'));

    Future<List<String>> setIds() async =>
        ((await adminSet())?['userIds'] as List? ?? const []).cast<String>();

    Future<List<String>> enabledAdmins() async => [
          for (final user in await store.listUsers())
            if (user.isEnabledAdmin) user.id,
        ];

    for (final (name, change)
        in <(String, Future<User> Function(AccountService, User))>[
      (
        'demotions',
        (service, target) => service.updateUser(target, role: Role.reader)
      ),
      (
        'disablings',
        (service, target) => service.updateUser(target, disabled: true)
      ),
    ]) {
      test('concurrent $name always leave an enabled administrator', () async {
        // As the server and the command line would, on their own connections.
        final otherDb = Db(testMongoUri);
        await otherDb.open();
        addTearDown(otherDb.close);
        final otherProcess = AccountService(AccountStore(otherDb));

        for (var round = 0; round < 10; round++) {
          await db.collection(userCollection).deleteMany(<String, Object>{});
          await db
              .collection(adminSetCollection)
              .deleteMany(<String, Object>{});
          final first = await user('first@b.c', Role.admin);
          final second = await user('second@b.c', Role.admin);

          final outcomes = await Future.wait([
            statusOf(() => change(accounts, first)),
            statusOf(() => change(otherProcess, second)),
          ]);

          expect(
              outcomes, unorderedEquals([HttpStatus.ok, HttpStatus.conflict]),
              reason: 'round $round');
          expect(await enabledAdmins(), hasLength(1), reason: 'round $round');
        }
      });
    }

    /// An [AccountService] whose next demotion stops between its two writes,
    /// as a process does when it is suspended or loses its CPU.
    ///
    /// With [afterRead] it stops earlier, once it has read the user and before
    /// it has written anything.
    (AccountService, Future<void>, void Function()) stalled({
      bool afterRead = false,
    }) {
      final entered = Completer<void>();
      final resume = Completer<void>();
      Future<void> pause() async {
        if (!entered.isCompleted) entered.complete();
        await resume.future;
      }

      final service = AccountService(store,
          beforeAdminUserWrite: afterRead ? null : pause,
          afterAdminClassified: afterRead ? pause : null);
      return (service, entered.future, resume.complete);
    }

    Future<String?> codeOf(Future<User> Function() change) async {
      try {
        await change();
        return null;
      } on AccountException catch (error) {
        return error.code;
      }
    }

    Future<Map<dynamic, dynamic>> markers() async =>
        (await adminSet())?['removing'] as Map? ?? const {};

    test('a stalled demotion cannot be overtaken by another one', () async {
      final first = await user('a@b.c', Role.admin);
      final second = await user('b@b.c', Role.admin);
      final (slow, entered, resume) = stalled();

      final demotion = slow.updateUser(first, role: Role.reader);
      await entered;
      expect(await setIds(), [second.id]);

      expect(
          await statusOf(() => accounts.updateUser(second, role: Role.reader)),
          HttpStatus.conflict);
      resume();
      await demotion;

      expect(await enabledAdmins(), [second.id]);
      expect(await setIds(), [second.id]);
      expect((await adminSet())!['removing'], isEmpty);
    });

    test('a rebuild does not bring back a demotion still under way', () async {
      final first = await user('a@b.c', Role.admin);
      final second = await user('b@b.c', Role.admin);
      final (slow, entered, resume) = stalled();

      final demotion = slow.updateUser(first, role: Role.reader);
      await entered;
      await store.reconcileAdminSet(DateTime.now());
      expect(await setIds(), [second.id]);

      expect(await statusOf(() => accounts.updateUser(second, disabled: true)),
          HttpStatus.conflict);
      resume();
      await demotion;
      expect(await enabledAdmins(), [second.id]);
    });

    test('a failed write of the user puts the administrator back', () async {
      final first = await user('a@b.c', Role.admin);
      final second = await user('b@b.c', Role.admin);
      final failing = AccountService(store,
          beforeAdminUserWrite: () => Future.error(StateError('write lost')));

      await expectLater(failing.updateUser(first, role: Role.reader),
          throwsA(isA<StateError>()));

      expect(await enabledAdmins(), unorderedEquals([first.id, second.id]));
      expect(await setIds(), unorderedEquals([first.id, second.id]));
      expect((await adminSet())!['removing'], isEmpty);
      await accounts.updateUser(second, role: Role.reader);
      expect(await setIds(), [first.id]);
    });

    test('a process that died mid-demotion heals once its removal ages out',
        () async {
      final first = await user('a@b.c', Role.admin);
      final second = await user('b@b.c', Role.admin);
      final now = DateTime.now();
      expect(await store.takeFromAdminSet(first.id, now), isTrue);

      await store.reconcileAdminSet(
          now.add(adminRemovalGrace - const Duration(seconds: 1)));
      expect(await setIds(), [second.id]);

      await store.reconcileAdminSet(
          now.add(adminRemovalGrace + const Duration(seconds: 1)));
      expect(await setIds(), unorderedEquals([first.id, second.id]));
      expect((await adminSet())!['removing'], isEmpty);
    });

    test('a rebuild does not undo a removal made after it read the set',
        () async {
      final first = await user('a@b.c', Role.admin);
      final second = await user('b@b.c', Role.admin);

      await store.reconcileAdminSet(DateTime.now(),
          beforeReplace: () =>
              store.takeFromAdminSet(first.id, DateTime.now()).then((_) {}));

      expect(await setIds(), [second.id]);
    });

    test('a rebuild keeps a user promoted after it read the set', () async {
      final admin = await user('a@b.c', Role.admin);
      final promoted = await user('p@b.c', Role.publisher);

      var promotedYet = false;
      await store.reconcileAdminSet(DateTime.now(), beforeReplace: () async {
        if (promotedYet) return;
        promotedYet = true;
        await store.updateUser(promoted.id, DateTime.now(), role: Role.admin);
        await store.addToAdminSet(promoted.id);
      });

      expect(await setIds(), unorderedEquals([admin.id, promoted.id]));
    });

    test('a rebuild replaces a corrupted set', () async {
      final first = await user('a@b.c', Role.admin);
      final second = await user('b@b.c', Role.admin);
      final disabled = await user('c@b.c', Role.admin);
      await store.updateUser(disabled.id, DateTime.now(), disabled: true);
      await user('d@b.c', Role.publisher);
      await db
          .collection(adminSetCollection)
          .replaceOne(where.eq('_id', 'enabled_admins'), {
        'userIds': ['ghost', disabled.id],
        'removing': 'garbage'
      });

      await store.reconcileAdminSet(DateTime.now());

      expect(await setIds(), unorderedEquals([first.id, second.id]));
      expect((await adminSet())!['removing'], isEmpty);
      expect((await adminSet())!['version'], isA<int>());
    });

    test('an empty or missing set is rebuilt before refusing', () async {
      final first = await user('a@b.c', Role.admin);
      final second = await user('b@b.c', Role.admin);
      await db.collection(adminSetCollection).deleteMany(<String, Object>{});

      await accounts.updateUser(first, role: Role.reader);

      expect(await enabledAdmins(), [second.id]);
      expect(await setIds(), [second.id]);
    });

    test('an id that is no longer an administrator does not count', () async {
      final only = await user('a@b.c', Role.admin);
      await db.collection(adminSetCollection).updateOne(
          where.eq('_id', 'enabled_admins'),
          modify.set('userIds', [only.id, '0123456789abcdef01234567']));

      expect(await statusOf(() => accounts.updateUser(only, role: Role.reader)),
          HttpStatus.conflict);
      expect((await store.findUserById(only.id))!.isEnabledAdmin, isTrue);
      expect(await setIds(), [only.id]);
    });

    test('the last id cannot be taken from the set', () async {
      final only = await user('a@b.c', Role.admin);
      final before = (await adminSet())!['version'];

      expect(await store.takeFromAdminSet(only.id, DateTime.now()), isFalse);

      final after = (await adminSet())!;
      expect(after['version'], before);
      expect(after['userIds'], [only.id]);
    });

    test('a refused removal changes nothing', () async {
      final only = await user('a@b.c', Role.admin);
      expect(await statusOf(() => accounts.updateUser(only, role: Role.reader)),
          HttpStatus.conflict);
      expect(await setIds(), [only.id]);
      expect((await adminSet())!['removing'] ?? const {}, isEmpty);
    });

    test('the state is read again before changing anything', () async {
      final admin = await user('a@b.c', Role.admin);
      final stale = await user('p@b.c', Role.publisher);
      await store.updateUser(stale.id, DateTime.now(), role: Role.admin);
      await store.updateUser(admin.id, DateTime.now(), role: Role.reader);

      expect(
          await statusOf(() => accounts.updateUser(stale, role: Role.reader)),
          HttpStatus.conflict);
      expect((await store.findUserById(stale.id))!.role, Role.admin);
    });

    test('a change of a non-admin leaves the set alone', () async {
      final admin = await user('a@b.c', Role.admin);
      final other = await user('o@b.c', Role.publisher);
      final before = (await adminSet())!['version'];
      await accounts.updateUser(other, role: Role.reader);
      await accounts.updateUser(other, disabled: true);
      expect((await store.findUserById(other.id))!.disabled, isTrue);
      expect(await setIds(), [admin.id]);
      expect((await adminSet())!['version'], before);
    });

    test('becoming or ceasing to be an enabled admin updates the set',
        () async {
      final admin = await user('a@b.c', Role.admin);
      final other = await user('o@b.c', Role.publisher);

      await accounts.updateUser(other, role: Role.admin);
      expect(await setIds(), unorderedEquals([admin.id, other.id]));

      await accounts.updateUser(other, disabled: true);
      expect(await setIds(), [admin.id]);

      await accounts.updateUser(other, disabled: false);
      expect(await setIds(), unorderedEquals([admin.id, other.id]));

      await accounts.updateUser(other, role: Role.publisher);
      expect(await setIds(), [admin.id]);
    });

    test('a refusal by the database is not taken for the last admin', () async {
      final first = await user('a@b.c', Role.admin);
      await user('b@b.c', Role.admin);
      final reply = await db.runCommand({
        'collMod': adminSetCollection,
        'validator': {
          'version': {r'$type': 'string'},
        },
      });
      expect(reply['ok'], 1.0);

      await expectLater(store.takeFromAdminSet(first.id, DateTime.now()),
          throwsA(isA<AdminSetException>()));
    });

    test('a user the database refuses to change stays an admin', () async {
      final first = await user('a@b.c', Role.admin);
      final second = await user('b@b.c', Role.admin);
      final reply = await db.runCommand({
        'collMod': userCollection,
        'validator': {
          'role': {r'$eq': 'admin'},
        },
      });
      expect(reply['ok'], 1.0);

      await expectLater(accounts.updateUser(first, role: Role.reader),
          throwsA(isA<StateError>()));

      expect(await setIds(), unorderedEquals([first.id, second.id]));
      expect((await store.findUserById(first.id))!.role, Role.admin);
    });

    test('a promotion cannot undo a removal under way, and the demotion wins',
        () async {
      final admin = await user('a@b.c', Role.admin);
      final target = await user('t@b.c', Role.reader);
      final (promoting, promotionRead, resumePromotion) =
          stalled(afterRead: true);
      final promotion =
          codeOf(() => promoting.updateUser(target, role: Role.admin));
      await promotionRead;

      await accounts.updateUser(target, role: Role.admin);
      final (demoting, demotionClaimed, resumeDemotion) = stalled();
      final demotion = demoting.updateUser(target, role: Role.reader);
      await demotionClaimed;
      final marker = (await markers())[target.id];
      expect(marker, isNotNull);

      resumePromotion();
      expect(await promotion, 'admin_change_in_progress');
      expect(await setIds(), [admin.id]);
      expect((await markers())[target.id], marker);

      expect(await codeOf(() => accounts.updateUser(admin, role: Role.reader)),
          'last_admin');
      resumeDemotion();
      await demotion;

      expect(await enabledAdmins(), [admin.id]);
      expect(await setIds(), [admin.id]);
      expect(await markers(), isEmpty);
    });

    test('a second removal of someone being removed is not called the last',
        () async {
      await user('a@b.c', Role.admin);
      final target = await user('t@b.c', Role.admin);
      final (demoting, claimed, resume) = stalled();
      final demotion = demoting.updateUser(target, role: Role.reader);
      await claimed;

      expect(await codeOf(() => accounts.updateUser(target, disabled: true)),
          'admin_change_in_progress');

      resume();
      await demotion;
    });

    test('a promotion overtaken by a demotion runs again and wins', () async {
      final admin = await user('a@b.c', Role.admin);
      final target = await user('t@b.c', Role.publisher);
      final (promoting, setWritten, resume) = stalled();
      final promotion = promoting.updateUser(target, role: Role.admin);
      await setWritten;
      expect(await setIds(), unorderedEquals([admin.id, target.id]));

      await accounts.updateUser(target, role: Role.reader);
      resume();
      final promoted = await promotion;

      expect(promoted.role, Role.admin);
      expect(await enabledAdmins(), unorderedEquals([admin.id, target.id]));
      expect(await setIds(), unorderedEquals([admin.id, target.id]));
      expect(await markers(), isEmpty);
    });

    test('a stale decision about a disabled admin goes through the guard',
        () async {
      final admin = await user('a@b.c', Role.admin);
      final target = await user('t@b.c', Role.admin);
      await accounts.updateUser(target, disabled: true);
      final (demoting, paused, resume) = stalled();
      final demotion =
          codeOf(() => demoting.updateUser(target, role: Role.reader));
      await paused;

      await accounts.updateUser(target, disabled: false);
      await accounts.updateUser(admin, role: Role.reader);
      resume();

      expect(await demotion, 'last_admin');
      expect(await enabledAdmins(), [target.id]);
      expect(await setIds(), [target.id]);
    });

    test('a demotion of a disabled admin overtaken by enabling it runs again',
        () async {
      final admin = await user('a@b.c', Role.admin);
      final target = await user('t@b.c', Role.admin);
      await accounts.updateUser(target, disabled: true);
      final (demoting, paused, resume) = stalled();
      final demotion = demoting.updateUser(target, role: Role.reader);
      await paused;

      await accounts.updateUser(target, disabled: false);
      expect(await setIds(), unorderedEquals([admin.id, target.id]));
      resume();
      await demotion;

      final latest = (await store.findUserById(target.id))!;
      expect(latest.role, Role.reader);
      expect(latest.disabled, isFalse);
      expect(await enabledAdmins(), [admin.id]);
      expect(await setIds(), [admin.id]);
      expect(await markers(), isEmpty);
    });

    test('enabling an admin overtaken by its demotion leaves no admin behind',
        () async {
      final admin = await user('a@b.c', Role.admin);
      final target = await user('t@b.c', Role.admin);
      await accounts.updateUser(target, disabled: true);
      final (enabling, setWritten, resume) = stalled();
      final enabled = enabling.updateUser(target, disabled: false);
      await setWritten;

      await accounts.updateUser(target, role: Role.reader);
      resume();
      await enabled;

      final latest = (await store.findUserById(target.id))!;
      expect(latest.role, Role.reader);
      expect(latest.disabled, isFalse);
      expect(await enabledAdmins(), [admin.id]);
      expect(await setIds(), [admin.id]);
    });

    test('someone still being promoted does not count as the remaining admin',
        () async {
      final admin = await user('a@b.c', Role.admin);
      final target = await user('t@b.c', Role.reader);
      final (promoting, setWritten, resume) = stalled();
      final promotion = promoting.updateUser(target, role: Role.admin);
      await setWritten;

      expect(await codeOf(() => accounts.updateUser(admin, role: Role.reader)),
          'last_admin');
      expect(await enabledAdmins(), [admin.id]);

      resume();
      await promotion;
      expect(await enabledAdmins(), unorderedEquals([admin.id, target.id]));

      await accounts.updateUser(admin, role: Role.reader);
      expect(await enabledAdmins(), [target.id]);
      expect(await setIds(), [target.id]);
    });

    test('a rebuild under constant contention gives up with a typed error',
        () async {
      await user('a@b.c', Role.admin);
      final other = await user('b@b.c', Role.publisher);

      await expectLater(
          store.reconcileAdminSet(DateTime.now(),
              beforeReplace: () => store.addToAdminSet(other.id)),
          throwsA(isA<AdminSetContentionException>()));
    });

    test('a promotion blocked by contention answers a conflict', () async {
      await user('a@b.c', Role.admin);
      final target = await user('t@b.c', Role.publisher);
      final contended = AccountService(_ContendedStore(db));

      expect(await codeOf(() => contended.updateUser(target, role: Role.admin)),
          'conflict');
      expect((await store.findUserById(target.id))!.role, Role.publisher);
    });

    test('a user that keeps changing gives up with a conflict', () async {
      final target = await user('t@b.c', Role.publisher);
      var writes = 0;
      final raced = AccountService(store, beforeAdminUserWrite: () async {
        writes++;
        await store.updateUser(target.id, DateTime.now(),
            disabled: writes.isOdd);
      });

      expect(await codeOf(() => raced.updateUser(target, role: Role.reader)),
          'conflict');

      expect(writes, 3);
      expect((await store.findUserById(target.id))!.role, Role.publisher);
    });

    test('a removal that finds the user changed clears its marker and retries',
        () async {
      final admin = await user('a@b.c', Role.admin);
      final target = await user('t@b.c', Role.admin);
      var interfered = false;
      final raced = AccountService(store, beforeAdminUserWrite: () async {
        if (interfered) return;
        interfered = true;
        await store.updateUser(target.id, DateTime.now(), disabled: true);
      });

      final updated = await raced.updateUser(target, role: Role.reader);

      expect(updated.role, Role.reader);
      expect(updated.disabled, isTrue);
      expect(await setIds(), [admin.id]);
      expect(await markers(), isEmpty);
    });

    test('a marker can only be cleared by the operation that set it', () async {
      final first = await user('a@b.c', Role.admin);
      final second = await user('b@b.c', Role.admin);
      final now = DateTime.now();
      expect(await store.takeFromAdminSet(first.id, now, operation: 'mine'),
          isTrue);

      await store.finishAdminRemoval(first.id, 'other');
      expect(await markers(), contains(first.id));
      await store.reconcileAdminSet(now, abandoned: 'other');
      expect(await markers(), contains(first.id));
      expect(await setIds(), [second.id]);

      await store.finishAdminRemoval(first.id, 'mine');
      expect(await markers(), isEmpty);
    });

    test('an addition is refused while a removal is marked', () async {
      final first = await user('a@b.c', Role.admin);
      final second = await user('b@b.c', Role.admin);
      expect(await store.takeFromAdminSet(first.id, DateTime.now()), isTrue);
      final before = await adminSet();

      expect(await store.addToAdminSet(first.id), isFalse);

      expect(await adminSet(), before);
      expect(await setIds(), [second.id]);
    });

    test(
        'the marker of a process that died after the user write does not '
        'block a later promotion', () async {
      final admin = await user('a@b.c', Role.admin);
      final target = await user('t@b.c', Role.admin);
      expect(await store.takeFromAdminSet(target.id, DateTime.now()), isTrue);
      await store.updateUser(target.id, DateTime.now(), role: Role.reader);

      await accounts.updateUser(target, role: Role.admin);

      expect(await setIds(), unorderedEquals([admin.id, target.id]));
      expect(await markers(), isEmpty);
    });

    test('a failed promotion leaves nothing in the set', () async {
      final admin = await user('a@b.c', Role.admin);
      final target = await user('t@b.c', Role.reader);
      final failing = AccountService(store,
          beforeAdminUserWrite: () => Future.error(StateError('write lost')));

      await expectLater(failing.updateUser(target, role: Role.admin),
          throwsA(isA<StateError>()));

      expect(await setIds(), [admin.id]);
      expect((await store.findUserById(target.id))!.role, Role.reader);
    });

    test('the compare-and-set reads old documents the way the model does',
        () async {
      await user('a@b.c', Role.admin);
      final noFlag = await user('n@b.c', Role.publisher);
      final oddRole = await user('o@b.c', Role.publisher);
      await db.collection(userCollection).updateOne(
          where.id(ObjectId.fromHexString(noFlag.id)),
          modify.unset('disabled'));
      await db.collection(userCollection).updateOne(
          where.id(ObjectId.fromHexString(oddRole.id)),
          modify.set('role', 'retired'));

      expect((await accounts.updateUser(noFlag, role: Role.reader)).role,
          Role.reader);
      expect((await accounts.updateUser(oddRole, role: Role.publisher)).role,
          Role.publisher);
    });
  });

  group('audit', () {
    Future<Map<String, dynamic>> event(String action) async {
      final events = await auditEvents(action);
      expect(events, isNotEmpty, reason: action);
      return events.last;
    }

    test('records logins with the address', () async {
      await user('r@b.c', Role.reader);
      await send('POST', '/webapi/login',
          body: {'email': 'r@b.c', 'password': _password},
          headers: {'x-forwarded-for': '203.0.113.9'});
      final record = await event('user.login');
      expect(record['actor'], 'r@b.c');
      expect(record['target'], 'r@b.c');
      expect(record['ip'], '203.0.113.9');
      expect(record['at'], isA<DateTime>());
    });

    test('records failed logins without the password', () async {
      await user('r@b.c', Role.reader);
      await send('POST', '/webapi/login',
          body: {'email': 'r@b.c', 'password': 'guessed-password'});
      final record = await event('user.login_failed');
      expect(record['target'], 'r@b.c');
      expect(record['details']['reason'], 'bad_password');
      expect(jsonEncode(record, toEncodable: (v) => '$v'),
          isNot(contains('guessed-password')));
    });

    test('records the actor of user administration', () async {
      final admin = await user('a@b.c', Role.admin);
      final browser = await login(admin);
      final created = await send('POST', '/webapi/users',
          browser: browser, body: {'email': 'n@b.c', 'role': 'reader'});
      final id = created.body['user']['id'];
      expect((await auditEvents('user.created')).last['actor'], 'a@b.c');

      await send('PATCH', '/webapi/users/$id',
          browser: browser, body: {'role': 'publisher'});
      final updated = await event('user.updated');
      expect(updated['actor'], 'a@b.c');
      expect(updated['target'], 'n@b.c');
      expect(updated['details'], {'role': 'publisher'});

      await send('POST', '/webapi/users/$id/password',
          browser: browser, body: {'password': 'a-new-password'});
      expect((await event('user.password_set'))['target'], 'n@b.c');
    });

    test('a request that changes nothing records nothing', () async {
      final admin = await user('a@b.c', Role.admin);
      await accounts.updateUser(admin, role: Role.admin);
      expect(await auditEvents('user.updated'), isEmpty);
    });

    test('records token creation and revocation', () async {
      final publisher = await user('p@b.c', Role.publisher);
      final created = await accounts.createToken(publisher, name: 'x');
      expect((await event('token.created'))['target'],
          'token:${created.token.prefix}');
      await accounts.revokeToken(created.token);
      expect((await event('token.revoked'))['target'],
          'token:${created.token.prefix}');
    });

    test('names the token as the actor of a publish', () async {
      final publisher = await user('p@b.c', Role.publisher);
      final created = await accounts.createToken(publisher, name: 'x');
      await publish('fresh', '1.0.0', bearer: created.secret);
      final record = await event('package.published');
      expect(record['actor'], 'token:${created.secret.substring(0, 8)}');
      expect(record['target'], 'fresh@1.0.0');
      expect(record['details']['uploader'], 'p@b.c');
    });

    test('records uploader changes', () async {
      final publisher = await user('p@b.c', Role.publisher);
      final secret = await token(publisher);
      await addPackage('owned', ['p@b.c', 'gone@b.c']);
      await send('POST', '/api/packages/owned/uploaders',
          bearer: secret, form: 'email=new%40b.c');
      await send('DELETE', '/api/packages/owned/uploaders/gone%40b.c',
          bearer: secret);
      expect((await event('uploader.added'))['target'], 'owned');
      expect((await event('uploader.added'))['details'], {'email': 'new@b.c'});
      expect(
          (await event('uploader.removed'))['details'], {'email': 'gone@b.c'});
    });

    group('when the database rejects the event', () {
      setUp(() async {
        final reply = await db.runCommand({
          'collMod': auditCollection,
          'validator': {
            'actor': {r'$type': 'int'},
          },
        });
        expect(reply['ok'], 1.0, reason: '$reply');
      });

      test('record throws', () async {
        expect(audit.record(AuditEvent(actor: 'a', action: 'x', target: 'y')),
            throwsA(isA<StateError>()));
      });

      test('recordSafely logs the loss and does not throw', () async {
        final records = <LogRecord>[];
        final subscription = Logger.root.onRecord.listen(records.add);
        addTearDown(subscription.cancel);

        await audit
            .recordSafely(AuditEvent(actor: 'a', action: 'x.y', target: 'z'));
        await pumpEventQueue();

        final failure = records.singleWhere((r) => r.level == Level.SEVERE);
        expect(failure.message, contains('failed to record audit event'));
        expect(failure.message, contains('x.y'));
        expect(await auditEvents('x.y'), isEmpty);
      });
    });

    test('a store that cannot record does not fail the request', () async {
      final failing = App(
        metaStore: MongoStore(db),
        packageStore: FileStore(storage.path),
        authenticator: const StaticTokenAuthenticator(bootstrapToken: 'secret'),
        auditStore: _FailingAuditStore(),
      );
      await addPackage('owned', ['p@b.c']);
      final reply = await send('POST', '/api/packages/owned/uploaders',
          bearer: 'secret', form: 'email=new%40b.c', using: failing);
      expect(reply.status, HttpStatus.ok);
    });
  });

  group('bootstrap', () {
    const config =
        AdminBootstrapConfig(email: 'root@b.c', password: 'bootstrap-password');

    late List<LogRecord> records;
    late StreamSubscription<LogRecord> subscription;

    setUp(() {
      records = [];
      Logger.root.level = Level.ALL;
      subscription = Logger.root.onRecord.listen(records.add);
    });

    tearDown(() => subscription.cancel());

    test('creates the admin on an empty collection', () async {
      await accounts.bootstrapAdmin(config);
      final user = (await store.findUserByEmail('root@b.c'))!;
      expect(user.role, Role.admin);
      expect(await accounts.verifyPassword(user, 'bootstrap-password'), isTrue);
      expect(records.map((r) => r.message),
          isNot(contains(contains('bootstrap-password'))));
    });

    test('does nothing once users exist and says so', () async {
      await user('someone@b.c', Role.reader);
      await accounts.bootstrapAdmin(config);
      expect(await store.findUserByEmail('root@b.c'), isNull);
      expect(records.map((r) => r.message),
          contains(contains('ignoring auth.admin.email')));
      expect(records.map((r) => r.message),
          isNot(contains(contains('bootstrap-password'))));
    });

    test('does not change an existing admin on the next start', () async {
      await accounts.bootstrapAdmin(config);
      final first = (await store.findUserByEmail('root@b.c'))!;
      await accounts.bootstrapAdmin(const AdminBootstrapConfig(
          email: 'root@b.c', password: 'other-password'));
      final second = (await store.findUserByEmail('root@b.c'))!;
      expect(second.passwordHash, first.passwordHash);
    });

    test('warns when there is nobody to log in', () async {
      await accounts.bootstrapAdmin(null);
      expect(records.map((r) => r.message),
          contains(contains('there are no users')));
    });

    test('the server creates the admin, indexes and warnings', () async {
      await db.dropCollection(userCollection);
      await db.dropCollection(tokenCollection);
      await db.dropCollection(sessionCollection);
      await db.dropCollection(auditCollection);
      final directory = await Directory.systemTemp.createTemp('unpub-boot-');
      addTearDown(() => directory.delete(recursive: true));

      final server = await UnpubServer.start(Config.parse(
        '''
server:
  host: 127.0.0.1
  port: 0
mongo:
  uri: $testMongoUri
storage:
  file:
    path: ${path.join(directory.path, 'packages')}
auth:
  bootstrapToken: legacy-token
  readTokens:
    - legacy-reader
  admin:
    email: root@b.c
    password: bootstrap-password
''',
        environment: const {},
      ));
      addTearDown(server.stop);

      final root = (await store.findUserByEmail('root@b.c'))!;
      expect(
          (await db
              .collection(adminSetCollection)
              .findOne(where.eq('_id', 'enabled_admins')))!['userIds'],
          [root.id]);
      final messages = records.map((r) => r.message).toList();
      expect(messages, contains(contains('auth.bootstrapToken is deprecated')));
      expect(messages, contains(contains('auth.readTokens is deprecated')));

      Future<Map<String, Map<String, dynamic>>> indexes(String name) async => {
            for (final index in await db.collection(name).getIndexes())
              index['name'] as String: index,
          };
      expect(
          (await indexes(userCollection))['email_unique']!['unique'], isTrue);
      expect(
          (await indexes(tokenCollection))['hash_unique']!['unique'], isTrue);
      expect(
          (await indexes(
              sessionCollection))['expiresAt_ttl']!['expireAfterSeconds'],
          0);
      expect((await indexes(auditCollection)).keys, contains('at_desc'));
    });
  });

  test('the server rebuilds the admin set when it starts', () async {
    final admin = await user('a@b.c', Role.admin);
    await db
        .collection(adminSetCollection)
        .replaceOne(where.eq('_id', 'enabled_admins'), {
      'userIds': const ['ghost']
    });
    final server = await UnpubServer.start(Config.parse(
      '''
server:
  host: 127.0.0.1
  port: 0
mongo:
  uri: $testMongoUri
storage:
  file:
    path: ${path.join(storage.path, 'rebuild')}
''',
      environment: const {},
    ));
    addTearDown(server.stop);

    expect(
        (await db
            .collection(adminSetCollection)
            .findOne(where.eq('_id', 'enabled_admins')))!['userIds'],
        [admin.id]);
  });

  group('cors', () {
    test('never allows a browser to send credentials', () async {
      final reply = await decode(await app.handler(shelf.Request(
        'GET',
        Uri.parse('http://internal:4000/webapi/packages'),
        headers: {'origin': 'https://evil.example.com'},
      )));
      expect(reply.headers['access-control-allow-credentials'], 'false');
    });

    test('does not let a preflight send the CSRF header', () async {
      final reply = await decode(await app.handler(shelf.Request(
        'OPTIONS',
        Uri.parse('http://internal:4000/webapi/tokens'),
        headers: {'origin': 'https://evil.example.com'},
      )));
      expect(reply.headers['access-control-allow-headers'],
          isNot(contains('csrf')));
    });
  });

  group('errors', () {
    test('an unknown route under webapi stays a 404', () async {
      expect((await send('GET', '/webapi/nope')).status, HttpStatus.notFound);
    });

    test('a body over the limit is rejected', () async {
      final reply = await send('POST', '/webapi/login', body: {
        'email': 'a@b.c',
        'password': 'x' * (70 * 1024),
      });
      expect(reply.status, HttpStatus.badRequest);
    });

    test('an embedder without accounts has no account routes', () async {
      final bare = App(
        metaStore: MongoStore(db),
        packageStore: FileStore(storage.path),
        authenticator: const StaticTokenAuthenticator(bootstrapToken: 'secret'),
      );
      expect(
          (await send('POST', '/webapi/login',
                  body: {'email': 'a@b.c', 'password': 'x'}, using: bare))
              .status,
          HttpStatus.notFound);
    });
  });
}

class _FailingAuditStore extends AuditStore {
  @override
  Future<void> record(AuditEvent event) async => throw StateError('down');
}

/// A store whose admin set never settles during a rebuild, and whose direct
/// additions are blocked, as if a removal marker were always present.
class _ContendedStore extends AccountStore {
  _ContendedStore(super.db);

  @override
  Future<bool> addToAdminSet(String userId) async => false;

  @override
  Future<void> reconcileAdminSet(
    DateTime now, {
    String? abandoned,
    Future<void> Function()? beforeReplace,
  }) async {
    throw const AdminSetContentionException('contended');
  }
}
