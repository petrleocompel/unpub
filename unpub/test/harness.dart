import 'dart:convert';
import 'dart:io';

import 'package:mongo_dart/mongo_dart.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';
import 'package:unpub/unpub.dart';

import 'utils.dart';

const harnessPassword = 'correct-horse-battery';
const _htmlAccept = 'text/html,application/xhtml+xml;q=0.9,*/*;q=0.8';

/// A response with its body read.
class Reply {
  final int status;
  final Map<String, String> headers;
  final Map<String, List<String>> headersAll;
  final String body;

  const Reply(this.status, this.headers, this.headersAll, this.body);

  String? get location => headers['location'];

  dynamic get json => jsonDecode(body);

  String? cookie(String name) {
    for (final header in headersAll['set-cookie'] ?? const <String>[]) {
      final match = RegExp('^$name=([^;]*)').firstMatch(header);
      if (match != null) return match.group(1);
    }
    return null;
  }

  /// The value of the hidden field [name] in the first form that has one.
  String field(String name) =>
      RegExp('name="$name" value="([^"]*)"').firstMatch(body)!.group(1)!;
}

/// What a browser holds after logging in.
class Browser {
  final String cookie;
  final String csrf;

  const Browser(this.cookie, this.csrf);
}

String encodeForm(Map<String, Object> fields) => [
      for (final MapEntry(:key, :value) in fields.entries)
        for (final item in value is List ? value : [value])
          '${Uri.encodeQueryComponent(key)}=${Uri.encodeQueryComponent('$item')}',
    ].join('&');

/// Collections the phase 5 tests write to, emptied before each test.
const harnessCollections = [
  'users',
  'tokens',
  'sessions',
  'admin_set',
  'audit',
  'packages',
  'stats',
  'version_stats',
  'upload_reservations',
  'object_locks',
  'webhooks',
  'webhook_deliveries',
  'upstream_cache',
  'upstream_archives',
];

/// A database, a storage directory, accounts and an [App] built from them,
/// fresh for every test of the group that calls [install].
class Harness {
  late Db db;
  late Directory storage;
  late AccountStore accountStore;
  late MongoAuditStore audit;
  late AccountService accounts;
  late App app;

  /// Builds the app of each test, given this harness.
  App Function(Harness harness)? builder;

  Harness({this.builder});

  MongoStore get metaStore => MongoStore(db);

  FileStore get packageStore => FileStore(storage.path);

  App buildApp({
    ReadAccess readAccess = ReadAccess.public,
    WebhookService? webhooks,
    Config? config,
    MetaStore? meta,
    UiConfig ui = const UiConfig(),
    bool secureCookies = false,
    String? bootstrapToken,
  }) =>
      App(
        metaStore: meta ?? metaStore,
        packageStore: packageStore,
        authenticator: ChainAuthenticator([
          ApiTokenAuthenticator(accountStore),
          SessionAuthenticator(accountStore),
          if (bootstrapToken != null)
            StaticTokenAuthenticator(
                bootstrapToken: bootstrapToken,
                bootstrapEmail: 'bootstrap@example.com'),
        ]),
        readAccess: readAccess,
        accountApi: AccountApi(accounts,
            limiter: LoginRateLimiter(), secureCookies: secureCookies),
        auditStore: audit,
        webhooks: webhooks,
        config: config,
        upstream: 'https://upstream.example',
        ui: ui,
      );

  void install() {
    setUpAll(() async {
      db = Db(testMongoUri);
      await db.open();
      storage = await Directory.systemTemp.createTemp('unpub-p5-');
    });

    tearDownAll(() async {
      await clean();
      await db.close();
      await storage.delete(recursive: true);
    });

    setUp(() async {
      await clean();
      if (await storage.exists()) await storage.delete(recursive: true);
      await storage.create(recursive: true);
      accountStore = AccountStore(db);
      audit = MongoAuditStore(db);
      await accountStore.ensureIndexes();
      await audit.ensureIndexes();
      await metaStore.ensureIndexes();
      accounts = AccountService(accountStore,
          audit: audit,
          hasher: const PasswordHasher(memoryKiB: 32, iterations: 1));
      app = builder?.call(this) ?? buildApp();
    });
  }

  Future<void> clean() async {
    for (final name in harnessCollections) {
      await db.dropCollection(name);
    }
  }

  Future<Reply> send(
    String method,
    String path, {
    String? bearer,
    Browser? as,
    Object? json,
    Map<String, Object>? form,
    bool csrf = true,
    bool html = false,
    Map<String, String> headers = const {},
    App? using,
  }) async {
    final String? body;
    final String? contentType;
    if (json != null) {
      body = jsonEncode(json);
      contentType = 'application/json';
    } else if (form != null || (as != null && method == 'POST')) {
      body = encodeForm({
        if (as != null && csrf) 'csrf_token': as.csrf,
        ...?form,
      });
      contentType = 'application/x-www-form-urlencoded';
    } else {
      body = null;
      contentType = null;
    }
    final response = await (using ?? app).handler(shelf.Request(
      method,
      Uri.parse('http://internal:4000$path'),
      headers: {
        if (html) 'accept': _htmlAccept,
        if (bearer != null) 'authorization': 'Bearer $bearer',
        if (as != null) 'cookie': '$sessionCookieName=${as.cookie}',
        if (as != null && json != null && csrf) 'x-csrf-token': as.csrf,
        if (contentType != null) 'content-type': contentType,
        ...headers,
      },
      body: body,
    ));
    final bytes = await response
        .read()
        .fold<List<int>>([], (all, chunk) => all..addAll(chunk));
    return Reply(response.statusCode, response.headers, response.headersAll,
        utf8.decode(bytes, allowMalformed: true));
  }

  /// A page as a browser asks for it.
  Future<Reply> page(String path, {Browser? as, App? using}) =>
      send('GET', path, as: as, html: true, using: using);

  /// A form post as a browser sends it, with the CSRF token unless [csrf] is
  /// false.
  Future<Reply> post(String path,
          {Browser? as,
          Map<String, Object> form = const {},
          bool csrf = true,
          App? using}) =>
      send('POST', path,
          as: as, form: form, csrf: csrf, html: true, using: using);

  Future<User> user(String email, Role role) =>
      accounts.createUser(email: email, role: role, password: harnessPassword);

  Future<String> token(User owner, {Set<Scope>? scopes}) async =>
      (await accounts.createToken(owner, name: 'test', scopes: scopes)).secret;

  /// Logs [email] in through the login form.
  Future<Browser> logIn(String email, {App? using}) async {
    final form = await page('/login', using: using);
    expect(form.status, HttpStatus.ok);
    final reply =
        await send('POST', '/login', html: true, using: using, headers: {
      'cookie': '$loginCookieName=${form.cookie(loginCookieName)}'
    }, form: {
      'email': email,
      'password': harnessPassword,
      'login_token': form.field('login_token'),
    });
    expect(reply.status, HttpStatus.seeOther, reason: reply.body);
    final cookie = reply.cookie(sessionCookieName)!;
    final account = await page('/account', as: Browser(cookie, ''));
    expect(account.status, HttpStatus.ok, reason: account.body);
    return Browser(cookie, account.field('csrf_token'));
  }

  /// Logs [email] in as the single-page client does, through
  /// `POST /webapi/login`.
  Future<Browser> apiLogIn(String email, {App? using}) async {
    final reply = await send('POST', '/webapi/login',
        using: using, json: {'email': email, 'password': harnessPassword});
    expect(reply.status, HttpStatus.ok, reason: reply.body);
    return Browser(reply.cookie(sessionCookieName)!,
        (reply.json as Map)['csrfToken'] as String);
  }

  /// Publishes [name] [version] through the upload route with [bearer], and
  /// fails the test unless that worked.
  Future<void> publish(String name, String version,
      {required String bearer, App? using}) async {
    final error = await tryPublish(name, version, bearer: bearer, using: using);
    expect(error, isNull, reason: 'publishing $name $version');
  }

  /// The error of publishing [name] [version], or null if it worked.
  Future<String?> tryPublish(String name, String version,
      {required String bearer, App? using}) async {
    final response = await (using ?? app).handler(uploadRequest(
        'name: $name\nversion: $version\ndescription: A test package.\n',
        {'authorization': 'Bearer $bearer'}));
    expect(response.statusCode, HttpStatus.found);
    return Uri.parse(response.headers['location']!).queryParameters['error'];
  }

  Future<Map<String, dynamic>?> packageDocument(String name) =>
      db.collection(packageCollection).findOne(where.eq('name', name));

  Future<List<Map<String, dynamic>>> auditEvents([String? action]) => db
      .collection(auditCollection)
      .find((action == null ? where : where.eq('action', action))
          .sortBy('at')
          .sortBy('_id'))
      .toList();

  /// The archive objects in storage, as `name-version` file names.
  List<String> storedArchives() => [
        for (final entity in storage.listSync(recursive: true))
          if (entity is File && entity.path.endsWith('.tar.gz'))
            entity.uri.pathSegments.last,
      ];
}
