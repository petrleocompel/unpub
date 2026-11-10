import 'dart:convert';
import 'dart:io';

import 'package:html/parser.dart' as html_parser;
import 'package:mongo_dart/mongo_dart.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';
import 'package:unpub/unpub.dart';

import 'utils.dart';

const _password = 'correct-horse-battery';
const _html = 'text/html,application/xhtml+xml;q=0.9,*/*;q=0.8';

/// A response with its body read.
class Page {
  final int status;
  final Map<String, String> headers;
  final Map<String, List<String>> headersAll;
  final String body;

  const Page(this.status, this.headers, this.headersAll, this.body);

  String? get location => headers['location'];

  /// The value of the cookie [name] this response sets.
  String? cookie(String name) {
    for (final header in headersAll['set-cookie'] ?? const <String>[]) {
      final match = RegExp('^$name=([^;]*)').firstMatch(header);
      if (match != null) return match.group(1);
    }
    return null;
  }

  String setCookieHeader(String name) => (headersAll['set-cookie'] ?? const [])
      .firstWhere((header) => header.startsWith('$name='));

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

String _form(Map<String, Object> fields) => [
      for (final MapEntry(:key, :value) in fields.entries)
        for (final item in value is List ? value : [value])
          '${Uri.encodeQueryComponent(key)}=${Uri.encodeQueryComponent('$item')}',
    ].join('&');

/// A store whose search always fails, to see the error page.
class _BrokenStore extends MongoStore {
  _BrokenStore(super.db);

  @override
  Future<UnpubQueryResult> searchPackages(PackageSearch search) =>
      throw StateError('broken');
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
      versionStatsCollection,
    ]) {
      await db.dropCollection(name);
    }
  }

  App buildApp({
    ReadAccess readAccess = ReadAccess.public,
    LoginRateLimiter? limiter,
    Uri? publicUrl,
    Config? config,
    MetaStore? metaStore,
    UpstreamProxy? upstreamProxy,
    bool withAccounts = true,
    String? bootstrapToken,
  }) =>
      App(
        metaStore: metaStore ?? MongoStore(db),
        packageStore: FileStore(storage.path),
        authenticator: ChainAuthenticator([
          if (bootstrapToken != null)
            StaticTokenAuthenticator(
                bootstrapToken: bootstrapToken,
                bootstrapEmail: 'admin@example.com'),
          ApiTokenAuthenticator(store),
          SessionAuthenticator(store),
        ]),
        readAccess: readAccess,
        accountApi: withAccounts
            ? AccountApi(accounts, limiter: limiter ?? LoginRateLimiter())
            : null,
        auditStore: audit,
        publicUrl: publicUrl,
        config: config,
        upstream: 'https://upstream.example',
        upstreamProxy: upstreamProxy,
      );

  setUpAll(() async {
    db = Db(testMongoUri);
    await db.open();
    storage = await Directory.systemTemp.createTemp('unpub-web-');
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
    await MongoStore(db).ensureIndexes();
    accounts = AccountService(store,
        audit: audit,
        hasher: const PasswordHasher(memoryKiB: 32, iterations: 1));
    app = buildApp();
  });

  Future<Page> fetch(
    String method,
    String path, {
    Browser? as,
    Map<String, Object>? form,
    bool csrf = true,
    bool html = true,
    Map<String, String> headers = const {},
    App? using,
  }) async {
    final fields = {
      if (as != null && csrf) 'csrf_token': as.csrf,
      ...?form,
    };
    final response = await (using ?? app).handler(shelf.Request(
      method,
      Uri.parse('http://internal:4000$path'),
      headers: {
        if (html) 'accept': _html,
        if (as != null) 'cookie': '$sessionCookieName=${as.cookie}',
        if (method == 'POST')
          'content-type': 'application/x-www-form-urlencoded',
        ...headers,
      },
      body: method == 'POST' ? _form(fields) : null,
    ));
    return Page(response.statusCode, response.headers, response.headersAll,
        await response.readAsString());
  }

  Future<User> user(String email, Role role) =>
      accounts.createUser(email: email, role: role, password: _password);

  /// Submits the login form like a browser, cookie included.
  Future<Page> submitLogin(String email, String password,
      {String? next, App? using}) async {
    final form = await fetch('GET', '/login', using: using);
    expect(form.status, HttpStatus.ok);
    return fetch('POST', '/login', using: using, headers: {
      'cookie': '$loginCookieName=${form.cookie(loginCookieName)}'
    }, form: {
      'email': email,
      'password': password,
      'login_token': form.field('login_token'),
      if (next != null) 'next': next,
    });
  }

  Future<Browser> logIn(String email, {App? using}) async {
    final reply = await submitLogin(email, _password, using: using);
    expect(reply.status, HttpStatus.seeOther, reason: reply.body);
    final cookie = reply.cookie(sessionCookieName)!;
    final account =
        await fetch('GET', '/account', as: Browser(cookie, ''), using: using);
    expect(account.status, HttpStatus.ok, reason: account.body);
    return Browser(cookie, account.field('csrf_token'));
  }

  Future<void> publish(
    String name,
    String version, {
    String description = 'A package for the tests.',
    Map<String, Object> pubspec = const {},
    String? readme,
    String? changelog,
    String uploader = 'owner@example.com',
    DateTime? at,
  }) =>
      MongoStore(db).addVersion(
          name,
          UnpubVersion(
            version,
            {
              'name': name,
              'version': version,
              'description': description,
              'environment': {'sdk': '^3.5.0'},
              ...pubspec,
            },
            null,
            uploader,
            readme,
            changelog,
            at ?? DateTime.now(),
            sha256: 'ab' * 32,
          ));

  Future<void> setDownloads(String name, int count) => db
      .collection(packageCollection)
      .updateOne(where.eq('name', name), modify.set('download', count));

  Future<List<String>> auditActions() async => [
        for (final event
            in await db.collection(auditCollection).find().toList())
          event['action'] as String,
      ];

  /// The package names on a list page, in order.
  List<String> listed(Page page) => [
        for (final match in RegExp(r'<h2><a href="/packages/([a-z0-9_]+)">')
            .allMatches(page.body))
          match.group(1)!,
      ];

  group('package list', () {
    test('renders the packages and escapes what they say', () async {
      await publish('alpha', '1.0.0',
          description: '<script>alert("x")</script> & more');
      await publish('beta', '0.1.0');
      final page = await fetch('GET', '/');
      expect(page.status, HttpStatus.ok);
      expect(page.headers['content-type'], startsWith('text/html'));
      expect(listed(page), unorderedEquals(['alpha', 'beta']));
      expect(
          page.body,
          contains(
              '&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; more'));
      expect(page.body, isNot(contains('<script>alert')));
      expect(page.body, startsWith('<!DOCTYPE html><html lang="en">'));
      expect((await fetch('GET', '/packages')).body, page.body);
    });

    test('searches names and descriptions', () async {
      await publish('yaml_tool', '1.0.0', description: 'Reads configuration.');
      await publish('fast_json', '1.0.0',
          description: 'A quick parser for documents.');
      await publish('other', '1.0.0', description: 'Unrelated.');

      expect(listed(await fetch('GET', '/packages?q=parser')), ['fast_json']);
      expect(listed(await fetch('GET', '/packages?q=Parser+documents')),
          ['fast_json']);
      expect(listed(await fetch('GET', '/packages?q=yaml_t')), ['yaml_tool']);
      expect(listed(await fetch('GET', '/packages?q=nothing')), isEmpty);
      final none = await fetch('GET', '/packages?q=%3Cb%3E');
      expect(none.body, contains('No packages match “&lt;b&gt;”'));
    });

    test('matches the same packages with and without the text index', () async {
      await publish('yaml_tool', '1.0.0', description: 'Reads configuration.');
      await publish('fast_json', '1.0.0',
          description: 'A quick parser for documents.');
      await publish('doc_tool', '1.0.0', description: 'Writes documents.');
      await publish('parser_kit', '1.0.0', description: 'Tokenizes source.');
      await publish('symbols', '1.0.0',
          description: r'Handles a+b, (c), [d], {e}, ^f$, g|h, back\slash, '
              '1.5 * and ?');
      await publish('plain', '1.0.0', description: 'Nothing special, 1x5.');
      await setDownloads('parser_kit', 100);

      const expected = {
        'parser': ['fast_json', 'parser_kit'],
        'parser documents': ['fast_json'],
        'Parser DOCUMENTS': ['fast_json'],
        'documents': ['fast_json', 'doc_tool'],
        'json quick': ['fast_json'],
        'pars': ['fast_json', 'parser_kit'],
        'yaml_t': ['yaml_tool'],
        '_tool': ['yaml_tool', 'doc_tool'],
        'absent': <String>[],
        'parser absent': <String>[],
        '1.5': ['symbols'],
        '.*': <String>[],
        'a+b': ['symbols'],
        '(c)': ['symbols'],
        '[d]': ['symbols'],
        '{e}': ['symbols'],
        r'^f$': ['symbols'],
        'g|h': ['symbols'],
        r'back\slash': ['symbols'],
        '*': ['symbols'],
        '?': ['symbols'],
        '"parser" -documents': <String>[],
      };
      Future<Map<String, List<String>>> search(String sort) async => {
            for (final query in expected.keys)
              query: listed(await fetch(
                  'GET',
                  '/packages?${Uri(queryParameters: {
                        'q': query,
                        'sort': sort
                      }).query}')),
          };

      final indexed = await search('relevance');
      final byName = await search('name');
      // The text index puts the package whose description says "parser"
      // before the more downloaded one that has it in a part of its name.
      expect(listed(await fetch('GET', '/packages?q=parser')),
          ['fast_json', 'parser_kit']);
      expect(listed(await fetch('GET', '/packages?q=parser&size=1&page=2')),
          ['parser_kit']);

      await db.runCommand(
          {'dropIndexes': packageCollection, 'index': packageTextIndexName});
      final fallback = await search('relevance');
      for (final MapEntry(key: query, value: names) in expected.entries) {
        expect(indexed[query], unorderedEquals(names), reason: query);
        expect(byName[query], unorderedEquals(names), reason: query);
        expect(fallback[query], unorderedEquals(names), reason: query);
      }
      expect(listed(await fetch('GET', '/packages?q=parser')),
          ['parser_kit', 'fast_json']);
    });

    test('filters by SDK and hides discontinued packages', () async {
      await publish('plain', '1.0.0');
      await publish('widgets', '1.0.0', pubspec: {
        'dependencies': {
          'flutter': {'sdk': 'flutter'},
        },
      });
      await publish('plugin', '1.0.0', pubspec: {
        'environment': {'sdk': '^3.5.0', 'flutter': '>=3.0.0'},
      });
      await publish('old', '1.0.0');
      await MongoStore(db).setDiscontinued('old', discontinued: true);

      expect(listed(await fetch('GET', '/packages?sdk=flutter')),
          unorderedEquals(['widgets', 'plugin']));
      expect(listed(await fetch('GET', '/packages?sdk=dart')), ['plain']);
      expect(listed(await fetch('GET', '/packages')),
          unorderedEquals(['plain', 'widgets', 'plugin']));
      final all = await fetch('GET', '/packages?discontinued=1');
      expect(
          listed(all), unorderedEquals(['plain', 'widgets', 'plugin', 'old']));
      expect(all.body, contains('badge discontinued'));
      expect(all.body, contains('badge flutter'));
    });

    test('sorts by downloads, update time and name', () async {
      final start = DateTime.utc(2026, 1, 1);
      await publish('charlie', '1.0.0', at: start);
      await publish('alpha', '1.0.0', at: start.add(const Duration(days: 2)));
      await publish('bravo', '1.0.0', at: start.add(const Duration(days: 1)));
      await setDownloads('charlie', 5);
      await setDownloads('bravo', 50);

      expect(listed(await fetch('GET', '/packages')),
          ['bravo', 'charlie', 'alpha']);
      expect(listed(await fetch('GET', '/packages?sort=updated')),
          ['alpha', 'bravo', 'charlie']);
      expect(listed(await fetch('GET', '/packages?sort=name')),
          ['alpha', 'bravo', 'charlie']);
      expect(listed(await fetch('GET', '/packages?sort=bogus')),
          ['bravo', 'charlie', 'alpha']);
    });

    test('pages through the list within its limits', () async {
      for (var i = 0; i < 25; i++) {
        await publish('pkg_${i.toString().padLeft(2, '0')}', '1.0.0');
      }
      final first = await fetch('GET', '/packages?sort=name');
      expect(listed(first), hasLength(20));
      expect(first.body, contains('Showing 1–20 of 25 packages.'));
      expect(first.body, contains('href="/packages?sort=name&amp;page=2"'));

      final second = await fetch('GET', '/packages?sort=name&page=2');
      expect(
          listed(second), ['pkg_20', 'pkg_21', 'pkg_22', 'pkg_23', 'pkg_24']);
      expect(second.body, contains('rel="prev"'));
      expect(second.body, isNot(contains('rel="next"')));

      final beyond = await fetch('GET', '/packages?page=9');
      expect(beyond.status, HttpStatus.ok);
      expect(listed(beyond), isEmpty);
      expect(beyond.body, contains('No packages on page 9, there are 25.'));

      for (final page in ['0', '-3', 'abc']) {
        expect(listed(await fetch('GET', '/packages?sort=name&page=$page')),
            listed(first));
      }
      expect(listed(await fetch('GET', '/packages?size=5&page=5&sort=name')),
          ['pkg_20', 'pkg_21', 'pkg_22', 'pkg_23', 'pkg_24']);
      expect(listed(await fetch('GET', '/packages?size=1000')), hasLength(25));
      expect(listed(await fetch('GET', '/packages?size=0')), hasLength(1));
    });

    test('a page or size out of range is an empty page, not an error',
        () async {
      await publish('alpha', '1.0.0');
      const huge = '9223372036854775807';
      for (final query in [
        'page=$huge',
        'page=$huge&size=$huge',
        'page=$huge&q=alpha',
        'page=$huge&q=alpha&sort=name',
        'page=$huge&partial=1',
        'page=-$huge',
        'page=99999999999999999999',
        'size=$huge',
        'size=-$huge',
      ]) {
        final page = await fetch('GET', '/packages?$query');
        expect(page.status, HttpStatus.ok, reason: query);
        expect(page.body, isNot(contains('Something went wrong')));
      }
      final beyond = await fetch('GET', '/packages?page=$huge');
      expect(listed(beyond), isEmpty);
      expect(beyond.body, contains('No packages on page 100000, there are 1.'));
      expect(listed(await fetch('GET', '/packages?page=-$huge')), ['alpha']);
      expect(listed(await fetch('GET', '/packages?size=$huge')), ['alpha']);

      // A search given to the store directly is bounded too.
      const unbounded = PackageSearch(page: 1 << 62, size: 1 << 62);
      expect(unbounded.limit, maxSearchSize);
      expect(unbounded.offset, maxSearchPage * maxSearchSize);
      expect(const PackageSearch(page: -5, size: -5).offset, 0);
      for (final text in [null, 'alpha']) {
        final result = await MongoStore(db).searchPackages(PackageSearch(
            page: 1 << 62,
            size: 1 << 62,
            text: text,
            sort: text == null ? PackageSort.name : PackageSort.relevance));
        expect(result.count, 1);
        expect(result.packages, isEmpty);
      }
    });

    test('offers the relevance sort only with a search', () async {
      await publish('alpha', '1.0.0');
      List<(String, bool)> sortOptions(Page page) => [
            for (final option in html_parser
                .parse(page.body)
                .querySelectorAll('select[name="sort"] option'))
              (
                option.attributes['value']!,
                option.attributes.containsKey('selected')
              ),
          ];

      final searched = await fetch('GET', '/packages?q=alpha');
      expect(sortOptions(searched), [
        ('relevance', true),
        ('downloads', false),
        ('updated', false),
        ('name', false),
      ]);
      final byName = await fetch('GET', '/packages?q=alpha&sort=name');
      expect(sortOptions(byName).first, ('relevance', false));
      expect(sortOptions(byName).last, ('name', true));
      expect(
          sortOptions(
              await fetch('GET', '/packages?q=alpha&sort=relevance&page=2')),
          contains(('relevance', true)));

      for (final path in ['/packages', '/packages?sort=relevance', '/']) {
        final page = await fetch('GET', path);
        expect(page.status, HttpStatus.ok, reason: path);
        expect(listed(page), ['alpha'], reason: path);
        expect(sortOptions(page), [
          ('downloads', true),
          ('updated', false),
          ('name', false),
        ]);
      }
      // A stale relevance sort without a search is the default one, left
      // out of the links.
      await publish('beta', '1.0.0');
      final stale = await fetch('GET', '/packages?sort=relevance&size=1');
      expect(stale.body, contains('href="/packages?size=1&amp;page=2"'));
      expect(stale.body, isNot(contains('sort=relevance')));
    });

    test('answers a partial list for search as you type', () async {
      await publish('alpha', '1.0.0');
      final partial = await fetch('GET', '/packages?q=alpha&partial=1');
      expect(partial.status, HttpStatus.ok);
      expect(listed(partial), ['alpha']);
      expect(partial.body, isNot(contains('<html')));
      expect(partial.headers['content-security-policy'], isNotNull);
    });
  });

  group('package page', () {
    const readme = '''
# Hello

<script>alert(1)</script>
<img src="x.png" onerror="alert(2)">
<p align="center" style="color: red" onclick="alert(3)">centered</p>

[bad](javascript:alert(4)) [data](data:text/html,hi) [ext](https://example.com/docs) [local](#usage)

<a href="JaVaScRiPt:alert(5)">mixed</a> <iframe src="https://evil.example"></iframe>

```dart
void main() {}
```

| a | b |
|:-:|---|
| 1 | 2 |
''';

    test('renders the README sanitized', () async {
      await publish('alpha', '1.0.0', readme: readme);
      final page = await fetch('GET', '/packages/alpha');
      expect(page.status, HttpStatus.ok);
      final body = page.body;
      expect(body, contains('<h1>Hello</h1>'));
      expect(body, isNot(contains('<script>alert')));
      expect(body, isNot(contains('alert(1)')));
      expect(body, isNot(contains('onerror')));
      expect(body, isNot(contains('onclick')));
      expect(body.toLowerCase(), isNot(contains('javascript:')));
      expect(body, isNot(contains('data:text')));
      expect(body, isNot(contains('iframe')));
      expect(body, isNot(contains('style=')));
      expect(body, contains('<img src="x.png">'));
      expect(body, contains('<p align="center">centered</p>'));
      expect(
          body,
          contains('<a href="https://example.com/docs" '
              'rel="nofollow noopener" target="_blank">ext</a>'));
      expect(body, contains('<a href="#usage">local</a>'));
      expect(body, contains('<code class="language-dart">'));
      expect(body, contains('<th align="center">a</th>'));
    });

    test('shows the changelog, versions and install tabs', () async {
      await publish('alpha', '1.0.0',
          changelog: '## 1.0.0\n\n- First.', uploader: 'first@example.com');
      await publish('alpha', '1.1.0',
          changelog: '## 1.1.0\n\n- Second.', uploader: 'second@example.com');
      await MongoStore(db)
          .setVersionRetracted('alpha', '1.1.0', retracted: true);

      final changelog = await fetch('GET', '/packages/alpha?tab=changelog');
      expect(changelog.body, contains('<h2>1.0.0</h2>'));
      expect(changelog.body, contains('aria-current="page">Changelog'));

      final versions = await fetch('GET', '/packages/alpha?tab=versions');
      expect(versions.body, contains('href="/packages/alpha/versions/1.1.0"'));
      expect(versions.body, contains('second@example.com'));
      expect(versions.body, contains('badge retracted'));
      expect(versions.body,
          contains('<code title="${'ab' * 32}">${'ab' * 6}</code>'));
      expect(versions.body.indexOf('versions/1.1.0'),
          lessThan(versions.body.indexOf('versions/1.0.0')));

      expect((await fetch('GET', '/packages/alpha?tab=other')).body,
          contains('aria-current="page">README'));
    });

    test('the install snippet uses the public URL', () async {
      await publish('alpha', '1.2.3');
      final page = await fetch('GET', '/packages/alpha?tab=install',
          using: buildApp(publicUrl: Uri.parse('https://pub.example.com/')));
      expect(page.body,
          contains('dart pub add alpha --hosted-url https://pub.example.com<'));
      expect(page.body, contains('hosted: https://pub.example.com\n'));
      expect(page.body, contains('version: ^1.2.3'));
      expect(page.body, contains('data-copy="install-add"'));

      final fromRequest = await fetch('GET', '/packages/alpha?tab=install');
      expect(fromRequest.body, contains('--hosted-url http://internal:4000<'));
    });

    test('shows the metadata in the sidebar', () async {
      await publish('base', '1.0.0');
      await publish('alpha', '1.0.0', pubspec: {
        'environment': {'sdk': '^3.5.0', 'flutter': '>=3.10.0'},
        'repository': 'https://git.example.com/alpha',
        'homepage': 'javascript:alert(1)',
        'dependencies': {
          'base': '^1.0.0',
          'http': '^1.0.0',
          'flutter': {'sdk': 'flutter'},
        },
        'flutter': {
          'plugin': {
            'platforms': {'android': {}, 'ios': {}},
          },
        },
      });
      final body = (await fetch('GET', '/packages/alpha')).body;
      expect(body, contains('<code>^3.5.0</code>'));
      expect(body, contains('<code>&gt;=3.10.0</code>'));
      expect(body, contains('<span class="badge">android</span>'));
      expect(body, contains('<a href="/packages/base">base</a>'));
      expect(body, contains('href="https://upstream.example/packages/http"'));
      expect(body, contains('<li>flutter'));
      expect(body, contains('href="https://git.example.com/alpha"'));
      expect(body, isNot(contains('javascript:')));
      expect(body, contains('owner@example.com'));
    });

    test('shows a version page', () async {
      await publish('alpha', '1.0.0', readme: 'Old readme');
      await publish('alpha', '2.0.0', readme: 'New readme');
      final page = await fetch('GET', '/packages/alpha/versions/1.0.0');
      expect(page.status, HttpStatus.ok);
      expect(page.body, contains('Old readme'));
      expect(page.body, contains('This is not the latest version'));
      expect(page.body,
          contains('href="/packages/alpha/versions/1.0.0?tab=changelog"'));
      expect(
          (await fetch('GET', '/packages/alpha')).body, contains('New readme'));

      final missing = await fetch('GET', '/packages/alpha/versions/3.0.0');
      expect(missing.status, HttpStatus.notFound);
      expect(missing.body, contains('alpha has no version 3.0.0.'));
    });

    test('shows a discontinued notice', () async {
      await publish('alpha', '1.0.0');
      await MongoStore(db)
          .setDiscontinued('alpha', discontinued: true, replacedBy: 'beta');
      final body = (await fetch('GET', '/packages/alpha')).body;
      expect(body, contains('This package is discontinued'));
      expect(body, contains('<a href="/packages/beta">beta</a>'));
    });

    test('an unknown package is a 404 page for browsers', () async {
      final page = await fetch('GET', '/packages/missing');
      expect(page.status, HttpStatus.notFound);
      expect(page.headers['content-type'], startsWith('text/html'));
      expect(page.body, contains('There is no package missing'));
      expect(page.body, contains('https://upstream.example/packages/missing'));
    });

    test('an unknown package goes to the upstream in proxy mode', () async {
      final proxy = UpstreamProxy(
        config: UpstreamConfig(
            url: Uri.parse('https://upstream.example'),
            mode: UpstreamMode.proxy,
            allowlist: const ['proxied']),
        cache: MongoUpstreamCacheStore(db),
        archives: FileStore(storage.path),
      );
      addTearDown(proxy.close);
      final proxying = buildApp(upstreamProxy: proxy);
      final page = await fetch('GET', '/packages/proxied', using: proxying);
      expect(page.status, HttpStatus.found);
      expect(page.location, 'https://upstream.example/packages/proxied');
      expect((await fetch('GET', '/packages/other', using: proxying)).status,
          HttpStatus.notFound);
    });

    test('unknown paths are a 404 page for browsers only', () async {
      final page = await fetch('GET', '/nothing/here');
      expect(page.status, HttpStatus.notFound);
      expect(page.headers['content-type'], startsWith('text/html'));

      final api = await fetch('GET', '/nothing/here', html: false);
      expect(api.status, HttpStatus.notFound);
      expect(api.body, 'Route not found');

      final pub = await fetch('GET', '/api/packages/missing/nope');
      expect(pub.headers['content-type'], isNot(startsWith('text/html')));
    });

    test('an error is a 500 page for browsers', () async {
      final broken = buildApp(metaStore: _BrokenStore(db));
      final page = await fetch('GET', '/', using: broken);
      expect(page.status, HttpStatus.internalServerError);
      expect(page.headers['content-type'], startsWith('text/html'));
      expect(page.body, isNot(contains('broken')));
    });

    test('the JSON endpoints keep working', () async {
      await publish('alpha', '1.0.0');
      final list = await fetch('GET', '/webapi/packages', html: false);
      expect(json.decode(list.body)['data']['count'], 1);
      final versions = await fetch('GET', '/packages/alpha.json');
      expect(json.decode(versions.body), {
        'name': 'alpha',
        'versions': ['1.0.0'],
      });
    });
  });

  group('headers', () {
    test('pages carry a strict content security policy', () async {
      await publish('alpha', '1.0.0', readme: '# Hi');
      for (final path in ['/', '/packages/alpha', '/login']) {
        final page = await fetch('GET', path);
        final policy = page.headers['content-security-policy']!;
        expect(policy, contains("default-src 'none'"));
        expect(policy, contains("script-src 'self'"));
        expect(policy, contains("style-src 'self'"));
        expect(policy, contains("frame-ancestors 'none'"));
        expect(policy, contains("form-action 'self'"));
        expect(policy, contains("base-uri 'none'"));
        expect(policy, isNot(contains('unsafe-inline')));
        expect(page.headers['x-content-type-options'], 'nosniff');
        expect(
            page.headers['referrer-policy'], 'strict-origin-when-cross-origin');
        // Nothing inline that the policy would block.
        expect(page.body, isNot(contains(RegExp(r'<script(?![^>]*\ssrc=)'))));
        expect(page.body, isNot(contains(' style=')));
        expect(page.body, isNot(contains(RegExp(r'\son[a-z]+='))));
      }
    });

    test('pages are not cached once signed in', () async {
      expect((await fetch('GET', '/')).headers['cache-control'],
          'private, max-age=0');
      await user('pub@example.com', Role.publisher);
      final browser = await logIn('pub@example.com');
      expect((await fetch('GET', '/', as: browser)).headers['cache-control'],
          'no-store');
    });

    test('static assets are cached with a validator', () async {
      final css = await fetch('GET', '/static/app.css');
      expect(css.status, HttpStatus.ok);
      expect(css.headers['content-type'], startsWith('text/css'));
      expect(css.headers['cache-control'], contains('max-age=31536000'));
      final etag = css.headers['etag']!;
      expect(css.body.split('\n').length, lessThan(400));

      final again = await fetch('GET', '/static/app.css',
          headers: {'if-none-match': etag});
      expect(again.status, HttpStatus.notModified);

      final js = await fetch('GET', '/static/app.js');
      expect(js.headers['content-type'], startsWith('text/javascript'));
      expect(js.headers['etag'], isNot(etag));

      expect(
          (await fetch('GET', '/static/other.js')).status, HttpStatus.notFound);
      expect((await fetch('GET', '/main.dart.js')).status, HttpStatus.notFound);
    });
  });

  group('login', () {
    setUp(() => user('pub@example.com', Role.publisher));

    test('sets the session cookie and goes back', () async {
      final reply =
          await submitLogin('PUB@example.com', _password, next: '/account');
      expect(reply.status, HttpStatus.seeOther);
      expect(reply.location, '/account');
      final cookie = reply.setCookieHeader(sessionCookieName);
      expect(cookie, contains('HttpOnly'));
      expect(cookie, contains('SameSite=Lax'));
      expect(cookie, isNot(contains('Secure')));
      expect(reply.cookie(loginCookieName), '');
      expect(await auditActions(), contains('user.login'));
    });

    test('a wrong password or an unknown user get the same message', () async {
      for (final (email, password) in [
        ('pub@example.com', 'wrong-password'),
        ('nobody@example.com', _password),
        ('not an email', _password),
      ]) {
        final reply = await submitLogin(email, password);
        expect(reply.status, HttpStatus.unauthorized);
        expect(reply.body, contains('Invalid email or password.'));
        expect(reply.cookie(sessionCookieName), isNull);
      }
    });

    test('too many failures are rate limited', () async {
      final limited = buildApp(limiter: LoginRateLimiter(maxFailures: 2));
      for (var i = 0; i < 2; i++) {
        expect(
            (await submitLogin('pub@example.com', 'wrong', using: limited))
                .status,
            HttpStatus.unauthorized);
      }
      final blocked =
          await submitLogin('pub@example.com', _password, using: limited);
      expect(blocked.status, HttpStatus.tooManyRequests);
      expect(blocked.headers['retry-after'], isNotNull);
      expect(blocked.body, contains('Too many failed attempts'));
    });

    test('only goes back to a path on this server', () async {
      for (final next in [
        '//evil.example/',
        'https://evil.example/',
        '/\\evil.example',
        'javascript:alert(1)',
        'account',
        '/login',
      ]) {
        final reply =
            await submitLogin('pub@example.com', _password, next: next);
        expect(reply.location, '/', reason: next);
      }
      final kept = await submitLogin('pub@example.com', _password,
          next: '/packages?q=a&sort=name');
      expect(kept.location, '/packages?q=a&sort=name');
    });

    test('needs the token of the login form', () async {
      final reply = await fetch('POST', '/login',
          form: {'email': 'pub@example.com', 'password': _password});
      expect(reply.status, HttpStatus.forbidden);
      expect(reply.cookie(sessionCookieName), isNull);

      final form = await fetch('GET', '/login');
      final mismatched = await fetch('POST', '/login', headers: {
        'cookie': '$loginCookieName=${form.cookie(loginCookieName)}',
      }, form: {
        'email': 'pub@example.com',
        'password': _password,
        'login_token': 'forged',
      });
      expect(mismatched.status, HttpStatus.forbidden);
    });

    test('logging out ends the session', () async {
      final browser = await logIn('pub@example.com');
      final reply = await fetch('POST', '/logout', as: browser);
      expect(reply.status, HttpStatus.seeOther);
      expect(reply.setCookieHeader(sessionCookieName), contains('Max-Age=0'));
      final after = await fetch('GET', '/account', as: browser);
      expect(after.status, HttpStatus.seeOther);
      expect(after.location, '/login?next=%2Faccount');
    });

    test('the page says when there are no accounts', () async {
      final page =
          await fetch('GET', '/login', using: buildApp(withAccounts: false));
      expect(page.status, HttpStatus.notFound);
    });
  });

  group('account', () {
    late User owner;

    setUp(() async {
      owner = await user('pub@example.com', Role.publisher);
    });

    test('lists, creates and revokes tokens', () async {
      final browser = await logIn('pub@example.com');
      await accounts.createToken(owner, name: 'existing <laptop>');

      final page = await fetch('GET', '/account', as: browser);
      expect(page.body, contains('existing &lt;laptop&gt;'));
      expect(page.body, contains('value="publish"'));

      final created =
          await fetch('POST', '/account/tokens', as: browser, form: {
        'name': 'ci',
        'scope': ['read'],
        'expiresIn': '30d'
      });
      expect(created.status, HttpStatus.created);
      final secret = RegExp(r'<code id="new-token">([^<]+)</code>')
          .firstMatch(created.body)!
          .group(1)!;
      expect(created.body, contains('dart pub token add http://internal:4000'));

      final again = await fetch('GET', '/account', as: browser);
      expect(again.body, isNot(contains(secret)));
      expect(again.body, contains('ci'));

      final tokens = await store.listTokens(owner.id);
      final ci = tokens.firstWhere((token) => token.name == 'ci');
      expect(ci.scopes, {Scope.read});
      expect(ci.expiresAt, isNotNull);

      final me = await fetch('GET', '/webapi/me',
          html: false, headers: {'authorization': 'Bearer $secret'});
      expect(me.status, HttpStatus.ok);

      final revoked =
          await fetch('POST', '/account/tokens/${ci.id}/revoke', as: browser);
      expect(revoked.status, HttpStatus.seeOther);
      expect(revoked.location, '/account?done=token-revoked');
      expect((await store.findTokenById(ci.id))!.revokedAt, isNotNull);
      expect((await fetch('GET', revoked.location!, as: browser)).body,
          contains('The token was revoked.'));
      expect(await auditActions(),
          containsAll(['token.created', 'token.revoked']));
    });

    test('reports a token that cannot be created', () async {
      final browser = await logIn('pub@example.com');
      final unnamed =
          await fetch('POST', '/account/tokens', as: browser, form: {
        'name': '',
        'scope': ['read']
      });
      expect(unnamed.status, HttpStatus.badRequest);
      expect(unnamed.body, contains('Name must have between 1 and 100'));

      final scopeless = await fetch('POST', '/account/tokens',
          as: browser, form: {'name': 'x'});
      expect(scopeless.status, HttpStatus.badRequest);
      expect(scopeless.body, contains('At least one scope is required.'));
    });

    test('a reader manages its own read tokens', () async {
      await user('reader@example.com', Role.reader);
      final browser = await logIn('reader@example.com');
      final page = await fetch('GET', '/account', as: browser);
      expect(page.body, isNot(contains('value="publish"')));

      final refused =
          await fetch('POST', '/account/tokens', as: browser, form: {
        'name': 'x',
        'scope': ['publish']
      });
      expect(refused.status, HttpStatus.forbidden);

      final created =
          await fetch('POST', '/account/tokens', as: browser, form: {
        'name': 'x',
        'scope': ['read']
      });
      expect(created.status, HttpStatus.created);
      final reader = await store.findUserByEmail('reader@example.com');
      final token = (await store.listTokens(reader!.id)).single;
      expect(
          (await fetch('POST', '/account/tokens/${token.id}/revoke',
                  as: browser))
              .status,
          HttpStatus.seeOther);
      expect((await fetch('POST', '/logout', as: browser)).status,
          HttpStatus.seeOther);
    });

    test('cannot revoke the token of someone else', () async {
      final other = await user('other@example.com', Role.publisher);
      final theirs = await accounts.createToken(other, name: 'theirs');
      final browser = await logIn('pub@example.com');
      final reply = await fetch(
          'POST', '/account/tokens/${theirs.token.id}/revoke',
          as: browser);
      expect(reply.status, HttpStatus.notFound);
      expect((await store.findTokenById(theirs.token.id))!.revokedAt, isNull);
    });

    test('changes the password', () async {
      final browser = await logIn('pub@example.com');
      final wrong = await fetch('POST', '/account/password',
          as: browser,
          form: {'currentPassword': 'nope', 'newPassword': 'another-password'});
      expect(wrong.status, HttpStatus.forbidden);
      expect(wrong.body, contains('The current password is wrong.'));

      final short = await fetch('POST', '/account/password',
          as: browser,
          form: {'currentPassword': _password, 'newPassword': 'short'});
      expect(short.status, HttpStatus.badRequest);

      final changed = await fetch('POST', '/account/password',
          as: browser,
          form: {
            'currentPassword': _password,
            'newPassword': 'another-password'
          });
      expect(changed.status, HttpStatus.seeOther);
      expect((await submitLogin('pub@example.com', 'another-password')).status,
          HttpStatus.seeOther);
      // The session that changed it stays valid.
      expect(
          (await fetch('GET', '/account', as: browser)).status, HttpStatus.ok);
    });

    test('forms without the CSRF token are refused', () async {
      final browser = await logIn('pub@example.com');
      for (final path in ['/account/tokens', '/logout', '/account/password']) {
        final missing = await fetch('POST', path,
            as: browser, csrf: false, form: {'name': 'x'});
        expect(missing.status, HttpStatus.forbidden, reason: path);
        expect(missing.headers['content-type'], startsWith('text/html'));
        expect(missing.body, contains('security token'));

        final wrong = await fetch('POST', path,
            as: browser, csrf: false, form: {'csrf_token': 'x', 'name': 'x'});
        expect(wrong.status, HttpStatus.forbidden, reason: path);
      }
      expect(await store.listTokens(owner.id), isEmpty);
    });

    test('anonymous visitors are sent to the login page', () async {
      final page = await fetch('GET', '/account');
      expect(page.status, HttpStatus.seeOther);
      expect(page.location, '/login?next=%2Faccount');

      final post = await fetch('POST', '/account/tokens', form: {'name': 'x'});
      expect(post.status, HttpStatus.seeOther);
      expect(post.location, '/login');
    });

    test('an API token cannot use the account pages', () async {
      final secret = (await accounts.createToken(owner, name: 't')).secret;
      final page = await fetch('GET', '/account',
          headers: {'authorization': 'Bearer $secret'});
      expect(page.status, HttpStatus.forbidden);
    });
  });

  group('admin', () {
    late User admin;

    const adminPages = [
      '/admin/users',
      '/admin/packages',
      '/admin/packages/alpha',
      '/admin/settings',
    ];

    setUp(() async {
      admin = await user('admin@example.com', Role.admin);
      await publish('alpha', '1.0.0');
      await publish('alpha', '1.1.0');
    });

    test('is closed to publishers, readers and visitors', () async {
      await user('pub@example.com', Role.publisher);
      await user('reader@example.com', Role.reader);
      for (final email in ['pub@example.com', 'reader@example.com']) {
        final browser = await logIn(email);
        for (final path in adminPages) {
          final page = await fetch('GET', path, as: browser);
          expect(page.status, HttpStatus.forbidden, reason: '$email $path');
          expect(page.headers['content-type'], startsWith('text/html'));
        }
        final post = await fetch('POST', '/admin/users', as: browser, form: {
          'email': 'new@example.com',
          'role': 'admin',
        });
        expect(post.status, HttpStatus.forbidden);
        final retract = await fetch(
            'POST', '/admin/packages/alpha/versions/1.0.0/retract',
            as: browser);
        expect(retract.status, HttpStatus.forbidden);
      }
      expect(await store.findUserByEmail('new@example.com'), isNull);
      expect((await fetch('GET', '/admin/users')).location,
          '/login?next=%2Fadmin%2Fusers');
    });

    test('needs a password session, whatever the token', () async {
      final tokenApp = buildApp(bootstrapToken: 'bootstrap-secret-token');
      final secrets = {
        'publish only': (await accounts
                .createToken(admin, name: 'publish', scopes: {Scope.publish}))
            .secret,
        'read only': (await accounts
                .createToken(admin, name: 'read', scopes: {Scope.read}))
            .secret,
        'all scopes': (await accounts.createToken(admin, name: 'all')).secret,
        'bootstrap': 'bootstrap-secret-token',
      };
      // The JSON API refuses a token without the read scope already.
      expect(
          (await fetch('GET', '/webapi/users',
                  html: false,
                  headers: {
                    'authorization': 'Bearer ${secrets['publish only']}'
                  },
                  using: tokenApp))
              .status,
          HttpStatus.forbidden);
      for (final MapEntry(key: kind, value: secret) in secrets.entries) {
        final bearer = {'authorization': 'Bearer $secret'};
        for (final path in adminPages) {
          final page =
              await fetch('GET', path, headers: bearer, using: tokenApp);
          expect(page.status, HttpStatus.forbidden, reason: '$kind $path');
          expect(page.headers['content-type'], startsWith('text/html'));
          expect(page.body, isNot(contains('href="/admin/packages/alpha"')));
          expect(page.body, isNot(contains('<td>admin@example.com')));
        }
        final created = await fetch('POST', '/admin/users',
            headers: bearer,
            using: tokenApp,
            form: {'email': 'new@example.com', 'role': 'admin'});
        expect(created.status, HttpStatus.forbidden, reason: kind);
        final retracted = await fetch(
            'POST', '/admin/packages/alpha/versions/1.0.0/retract',
            headers: bearer, using: tokenApp);
        expect(retracted.status, HttpStatus.forbidden, reason: kind);
      }
      expect(await store.findUserByEmail('new@example.com'), isNull);
      expect(
          (await MongoStore(db).queryPackage('alpha'))!
              .versions
              .first
              .isRetracted,
          isFalse);

      final browser = await logIn('admin@example.com', using: tokenApp);
      for (final path in adminPages) {
        expect((await fetch('GET', path, as: browser, using: tokenApp)).status,
            HttpStatus.ok,
            reason: path);
      }
    });

    test('manages users', () async {
      final browser = await logIn('admin@example.com');
      final page = await fetch('GET', '/admin/users', as: browser);
      expect(page.status, HttpStatus.ok);
      expect(page.body, contains('admin@example.com'));

      final created = await fetch('POST', '/admin/users', as: browser, form: {
        'email': 'New@Example.com',
        'displayName': '',
        'role': 'reader',
        'password': 'initial-password',
      });
      expect(created.status, HttpStatus.seeOther);
      expect(created.location, '/admin/users?done=user-created');
      final user = (await store.findUserByEmail('new@example.com'))!;
      expect(user.role, Role.reader);

      expect(
          (await fetch('POST', '/admin/users/${user.id}',
                  as: browser, form: {'role': 'publisher'}))
              .status,
          HttpStatus.seeOther);
      expect((await store.findUserById(user.id))!.role, Role.publisher);

      expect(
          (await fetch('POST', '/admin/users/${user.id}',
                  as: browser, form: {'disabled': 'true'}))
              .status,
          HttpStatus.seeOther);
      expect((await store.findUserById(user.id))!.disabled, isTrue);

      expect(
          (await fetch('POST', '/admin/users/${user.id}/password',
                  as: browser, form: {'password': 'replaced-password'}))
              .status,
          HttpStatus.seeOther);

      final duplicate = await fetch('POST', '/admin/users',
          as: browser, form: {'email': 'new@example.com', 'role': 'reader'});
      expect(duplicate.status, HttpStatus.conflict);
      expect(duplicate.body, contains('already exists'));

      final last = await fetch('POST', '/admin/users/${admin.id}',
          as: browser, form: {'role': 'reader'});
      expect(last.status, HttpStatus.conflict);
      expect(last.body, contains('last enabled administrator'));

      expect(await auditActions(),
          containsAll(['user.created', 'user.updated', 'user.password_set']));
    });

    test('manages packages', () async {
      final browser = await logIn('admin@example.com');
      expect((await fetch('GET', '/admin/packages', as: browser)).body,
          contains('href="/admin/packages/alpha"'));
      final page = await fetch('GET', '/admin/packages/alpha', as: browser);
      expect(page.status, HttpStatus.ok);

      final discontinued = await fetch(
          'POST', '/admin/packages/alpha/discontinue',
          as: browser, form: {'discontinued': '1', 'replacedBy': 'beta'});
      expect(discontinued.status, HttpStatus.seeOther);
      var package = (await MongoStore(db).queryPackage('alpha'))!;
      expect(package.isDiscontinued, isTrue);
      expect(package.replacedBy, 'beta');

      final itself = await fetch('POST', '/admin/packages/alpha/discontinue',
          as: browser, form: {'discontinued': '1', 'replacedBy': 'alpha'});
      expect(itself.status, HttpStatus.badRequest);
      expect(itself.body, contains('A package cannot replace itself.'));

      expect(
          (await fetch('POST', '/admin/packages/alpha/versions/1.0.0/retract',
                  as: browser))
              .status,
          HttpStatus.seeOther);
      package = (await MongoStore(db).queryPackage('alpha'))!;
      expect(package.versions.first.isRetracted, isTrue);
      expect(
          (await fetch('POST', '/admin/packages/alpha/versions/9.0.0/retract',
                  as: browser))
              .status,
          HttpStatus.notFound);

      expect(
          (await fetch('POST', '/admin/packages/alpha/uploaders',
                  as: browser, form: {'email': 'Helper@example.com'}))
              .status,
          HttpStatus.seeOther);
      package = (await MongoStore(db).queryPackage('alpha'))!;
      expect(package.uploaders, contains('helper@example.com'));
      expect(
          (await fetch('POST', '/admin/packages/alpha/uploaders/remove',
                  as: browser, form: {'email': 'owner@example.com'}))
              .status,
          HttpStatus.seeOther);
      package = (await MongoStore(db).queryPackage('alpha'))!;
      expect(package.uploaders, ['helper@example.com']);

      expect(
          (await fetch('GET', '/admin/packages/missing', as: browser)).status,
          HttpStatus.notFound);
      final events = await db.collection(auditCollection).find().toList();
      final actions = [for (final event in events) event['action']];
      expect(
          actions,
          containsAll([
            'package.discontinued',
            'version.retracted',
            'uploader.added',
            'uploader.removed',
          ]));
      final retraction =
          events.firstWhere((event) => event['action'] == 'version.retracted');
      expect(retraction['actor'], 'admin@example.com');
      expect(retraction['target'], 'alpha@1.0.0');
    });

    test('shows the settings without secrets', () async {
      final config = Config.parse('''
mongo:
  uri: mongodb://dbuser:mongo-secret-pw@db.example:27017/pub
storage:
  type: s3
  s3:
    bucket: packages
    region: eu-west-1
    accessKey: AKIAEXAMPLE
    secretKey: s3-secret-value
auth:
  bootstrapToken: bootstrap-secret-token
  admin:
    email: root@example.com
    password: admin-secret-pw
''', environment: const {});
      final configured = buildApp(config: config);
      final browser = await logIn('admin@example.com', using: configured);
      final page =
          await fetch('GET', '/admin/settings', as: browser, using: configured);
      expect(page.status, HttpStatus.ok);
      for (final secret in [
        'mongo-secret-pw',
        'dbuser',
        's3-secret-value',
        'AKIAEXAMPLE',
        'bootstrap-secret-token',
        'admin-secret-pw',
      ]) {
        expect(page.body, isNot(contains(secret)));
      }
      expect(page.body, contains('&lt;redacted&gt;'));
      expect(page.body, contains('db.example:27017/pub'));
      expect(page.body, contains('root@example.com'));
      expect(page.body, contains('packages'));
    });
  });

  group('authenticated read access', () {
    setUp(() async {
      app = buildApp(readAccess: ReadAccess.authenticated);
      await publish('alpha', '1.0.0');
    });

    test('sends anonymous browsers to the login page', () async {
      final home = await fetch('GET', '/');
      expect(home.status, HttpStatus.seeOther);
      expect(home.location, '/login');
      final package = await fetch('GET', '/packages/alpha?tab=versions');
      expect(
          package.location, '/login?next=%2Fpackages%2Falpha%3Ftab%3Dversions');
    });

    test('keeps the login page, assets and probes open', () async {
      expect((await fetch('GET', '/login')).status, HttpStatus.ok);
      expect((await fetch('GET', '/static/app.css')).status, HttpStatus.ok);
      expect((await fetch('GET', '/static/app.js')).status, HttpStatus.ok);
      expect((await fetch('GET', '/healthz')).status, HttpStatus.ok);
    });

    test('API clients still get a 401', () async {
      for (final path in ['/api/packages/alpha', '/webapi/packages', '/']) {
        final reply = await fetch('GET', path, html: false);
        expect(reply.status, HttpStatus.unauthorized, reason: path);
        expect(reply.headers['content-type'], contains('json'));
      }
      // Even when a browser asks.
      expect((await fetch('GET', '/api/packages/alpha')).status,
          HttpStatus.unauthorized);
    });

    test('a signed-in reader sees the packages', () async {
      await user('reader@example.com', Role.reader);
      final browser = await logIn('reader@example.com');
      final page = await fetch('GET', '/', as: browser);
      expect(page.status, HttpStatus.ok);
      expect(listed(page), ['alpha']);
      final install =
          await fetch('GET', '/packages/alpha?tab=install', as: browser);
      expect(install.body, contains('dart pub token add'));
    });
  });
}
