import 'dart:io';

import 'package:test/test.dart';
import 'package:unpub/src/web/spa.dart';
import 'package:unpub/unpub.dart';

import 'harness.dart';

const _client = 'test/fixtures/ui';
const _script = '/assets/index-3f2a1b.js';

const _spa = UiConfig(assetsDir: _client, mode: UiMode.spa);
const _ssr = UiConfig(assetsDir: _client, mode: UiMode.ssr);

void main() {
  group('shell markup', () {
    const index = '<!doctype html><html><head><meta charset="utf-8">'
        '<script type="module" src="./assets/a.js"></script>'
        '<link rel="stylesheet" href="/assets/a.css">'
        '<link rel="icon" href="https://cdn.example/x.svg"></head>'
        '<body><a href="//other.example/">x</a></body></html>';

    test('tells the client where it and the pages are', () {
      final shell = shellFor(index, basePath: '', classicPath: '/classic');
      expect(
          shell,
          contains('<head>\n<meta name="unpub-base" content="">\n'
              '<meta name="unpub-classic" content="/classic">'));
      expect(shell, contains('src="/assets/a.js"'));
      expect(shell, contains('href="/assets/a.css"'));
    });

    test('moves the references of the build under the base path', () {
      final shell = shellFor(index, basePath: '/app', classicPath: '');
      // A link to a page of the server is not one to the build.
      expect(
          shellFor('<head></head><a href="/classic/">x</a>',
              basePath: '/app', classicPath: ''),
          contains('href="/classic/"'));
      expect(shell, contains('<meta name="unpub-base" content="/app">'));
      expect(shell, contains('<meta name="unpub-classic" content="">'));
      expect(shell, contains('src="/app/assets/a.js"'));
      expect(shell, contains('href="/app/assets/a.css"'));
      // Other origins are left alone.
      expect(shell, contains('href="https://cdn.example/x.svg"'));
      expect(shell, contains('href="//other.example/"'));
    });

    test('content types of a Vite build', () {
      expect(contentTypeOf('a.js'), 'text/javascript; charset=utf-8');
      expect(contentTypeOf('a.css'), 'text/css; charset=utf-8');
      expect(contentTypeOf('a.woff2'), 'font/woff2');
      expect(contentTypeOf('a.svg'), 'image/svg+xml');
      expect(contentTypeOf('a.png'), 'image/png');
      expect(contentTypeOf('a.json'), 'application/json');
      expect(contentTypeOf('site.webmanifest'), 'application/manifest+json');
      expect(contentTypeOf('a.unknown-kind'), 'application/octet-stream');
    });
  });

  final harness = Harness(builder: (h) => h.buildApp(ui: _spa));
  harness.install();

  Future<Reply> get(String path,
          {bool html = true,
          Map<String, String> headers = const {},
          App? using,
          String method = 'GET'}) =>
      harness.send(method, path, html: html, headers: headers, using: using);

  void expectShell(Reply reply, {String base = ''}) {
    expect(reply.status, HttpStatus.ok, reason: reply.body);
    expect(reply.headers['content-type'], 'text/html; charset=utf-8');
    expect(reply.headers['cache-control'], 'no-store');
    expect(reply.headers['content-security-policy'],
        "$contentSecurityPolicy; font-src 'self'");
    expect(reply.headers['x-content-type-options'], 'nosniff');
    expect(reply.headers['x-frame-options'], 'DENY');
    expect(reply.body, contains('<meta name="unpub-base" content="$base">'));
    expect(reply.body, contains('src="$base$_script"'));
  }

  group('ui.mode spa', () {
    test('serves the shell at / and for every route of the client', () async {
      for (final path in [
        '/',
        '/packages',
        '/packages/alpha',
        '/packages/alpha/versions/1.0.0',
        '/login',
        '/account',
        '/admin/users',
        '/index.html',
      ]) {
        final reply = await get(path);
        expectShell(reply);
        expect(reply.body,
            contains('<meta name="unpub-classic" content="/classic">'));
      }
    });

    test('HEAD of the shell has its headers and no body', () async {
      final reply = await get('/packages/alpha', method: 'HEAD');
      expect(reply.status, HttpStatus.ok);
      expect(reply.headers['cache-control'], 'no-store');
      expect(reply.body, isEmpty);
    });

    test('a request that does not accept HTML gets no shell', () async {
      final reply = await get('/packages/alpha', html: false);
      expect(reply.status, HttpStatus.notFound);
      expect(reply.body, 'Route not found');
    });

    test('hashed assets are cached for good, with a validator', () async {
      final js = await get(_script, html: false);
      expect(js.status, HttpStatus.ok);
      expect(js.headers['content-type'], 'text/javascript; charset=utf-8');
      expect(
          js.headers['cache-control'], 'public, max-age=31536000, immutable');
      expect(js.body, contains('unpub fixture'));
      final etag = js.headers['etag']!;
      expect(etag, matches(RegExp(r'^"[0-9a-f]{32}"$')));

      final again =
          await get(_script, html: false, headers: {'if-none-match': etag});
      expect(again.status, HttpStatus.notModified);
      expect(again.body, isEmpty);
      expect(again.headers['etag'], etag);

      final head = await get(_script, method: 'HEAD', html: false);
      expect(head.status, HttpStatus.ok);
      expect(head.body, isEmpty);
      expect(head.headers['etag'], etag);

      final css = await get('/assets/index-9c8d7e.css', html: false);
      expect(css.headers['content-type'], 'text/css; charset=utf-8');
      final font = await get('/assets/inter-1a2b3c.woff2', html: false);
      expect(font.headers['content-type'], 'font/woff2');
      expect(font.headers['cache-control'], contains('immutable'));
    });

    test('other files are cached for an hour', () async {
      for (final (path, type) in [
        ('/favicon.svg', 'image/svg+xml'),
        ('/manifest.webmanifest', 'application/manifest+json'),
        ('/icon.png', 'image/png'),
        ('/client.json', 'application/json'),
      ]) {
        final reply = await get(path, html: false);
        expect(reply.status, HttpStatus.ok, reason: path);
        expect(reply.headers['content-type'], type, reason: path);
        expect(reply.headers['cache-control'], 'public, max-age=3600');
        expect(reply.headers['etag'], isNotNull);
      }
    });

    test('a missing asset is a 404, not the shell', () async {
      final reply = await get('/assets/missing-000000.js');
      expect(reply.status, HttpStatus.notFound);
      expect(reply.body, isNot(contains('unpub-base')));
    });

    test('nothing outside the build or hidden in it is served', () async {
      for (final path in [
        '/..%2fui_outside.txt',
        '/assets/..%2f..%2fui_outside.txt',
        '/%2e%2e%2fui_outside.txt',
        '/assets/..%5c..%5cui_outside.txt',
        '/.env',
        '/assets/%00.js',
      ]) {
        for (final html in [true, false]) {
          final reply = await get(path, html: html);
          expect(reply.status, HttpStatus.notFound, reason: path);
          expect(reply.body, isNot(contains('outside the client')));
          expect(reply.body, isNot(contains('hidden')));
        }
      }
    });

    test('dot segments are resolved before the build is looked at', () async {
      // The URL parser takes `%2e%2e` for `..`, so this is `/ui_outside.txt`,
      // which the build does not have.
      const path = '/assets/%2e%2e/%2e%2e/ui_outside.txt';
      expect((await get(path, html: false)).status, HttpStatus.notFound);
      final browser = await get(path);
      expectShell(browser);
      expect(browser.body, isNot(contains('outside the client')));
    });

    test('paths of the server never get the shell', () async {
      await harness.publish('alpha', '1.0.0',
          bearer: await harness
              .token(await harness.user('pub@example.com', Role.publisher)));
      for (final path in [
        '/api/packages/missing',
        '/api/nothing',
        '/webapi/nothing',
        '/packages/alpha/versions/9.9.9.tar.gz',
        '/packages/alpha.json',
        '/badge/v/alpha',
        '/healthz',
        '/readyz',
        '/metrics',
        '/static/app.css',
      ]) {
        final reply = await get(path);
        expect(reply.body, isNot(contains('unpub-base')), reason: path);
      }
      expect((await get('/packages/alpha.json')).status, HttpStatus.ok);
      expect((await get('/static/app.css')).status, HttpStatus.ok);
    });

    test('the server-rendered pages live under /classic', () async {
      final page = await get('/classic/');
      expect(page.status, HttpStatus.ok);
      expect(page.body, contains('<title>Packages · unpub</title>'));
      expect(page.body, contains('action="/classic/packages"'));
      expect(page.body, contains('href="/classic/login"'));
      final stylesheet =
          RegExp(r'href="(/classic/static/app\.css\?v=[0-9a-f]+)"')
              .firstMatch(page.body)!
              .group(1)!;
      final css = await get(stylesheet, html: false);
      expect(css.status, HttpStatus.ok);
      expect(css.headers['content-type'], startsWith('text/css'));
      expect((await get('/classic')).status, HttpStatus.ok);

      final missing = await get('/classic/nothing/here');
      expect(missing.status, HttpStatus.notFound);
      expect(missing.headers['content-type'], startsWith('text/html'));
      expect(missing.body, contains('href="/classic/"'));
    });

    test('logging in on the classic pages stays under /classic', () async {
      await harness.user('pub@example.com', Role.publisher);
      final form = await get('/classic/login?next=%2Faccount');
      expect(form.status, HttpStatus.ok);
      expect(form.body, contains('action="/classic/login"'));
      final cookie = form.headersAll['set-cookie']!
          .firstWhere((value) => value.startsWith('$loginCookieName='));
      expect(cookie, contains('Path=/classic/login;'));

      final reply =
          await harness.send('POST', '/classic/login', html: true, headers: {
        'cookie': '$loginCookieName=${form.cookie(loginCookieName)}'
      }, form: {
        'email': 'pub@example.com',
        'password': harnessPassword,
        'login_token': form.field('login_token'),
        'next': '/account',
      });
      expect(reply.status, HttpStatus.seeOther, reason: reply.body);
      expect(reply.location, '/classic/account');
      final browser = Browser(reply.cookie(sessionCookieName)!, '');
      final account = await harness.page('/classic/account', as: browser);
      expect(account.status, HttpStatus.ok);
      expect(account.body, contains('action="/classic/account/tokens"'));

      final out = await harness.post('/classic/logout',
          as: Browser(browser.cookie, account.field('csrf_token')));
      expect(out.status, HttpStatus.seeOther);
      expect(out.location, '/classic/');
    });

    test('a page that needs a login redirects under /classic', () async {
      final reply = await get('/classic/admin/users');
      expect(reply.status, HttpStatus.seeOther);
      expect(reply.location, '/classic/login?next=%2Fadmin%2Fusers');
    });
  });

  group('ui.mode spa with readAccess authenticated', () {
    late App private;

    setUp(() {
      private =
          harness.buildApp(ui: _spa, readAccess: ReadAccess.authenticated);
    });

    test('keeps the shell and its files open', () async {
      expectShell(await get('/', using: private));
      expectShell(await get('/packages/alpha', using: private));
      expect((await get(_script, html: false, using: private)).status,
          HttpStatus.ok);
      expect((await get('/favicon.svg', html: false, using: private)).status,
          HttpStatus.ok);
    });

    test('the API still answers 401', () async {
      for (final path in [
        '/webapi/v2/packages',
        '/webapi/me',
        '/api/packages/alpha',
        '/packages/alpha.json',
        '/packages/alpha/versions/1.0.0.tar.gz',
      ]) {
        for (final html in [true, false]) {
          final reply = await get(path, html: html, using: private);
          expect(reply.status, HttpStatus.unauthorized, reason: path);
          expect(reply.headers['content-type'], contains('json'));
        }
      }
    });

    test('the classic pages still redirect to their login', () async {
      final reply = await get('/classic/packages/alpha', using: private);
      expect(reply.status, HttpStatus.seeOther);
      expect(reply.location, '/classic/login?next=%2Fpackages%2Falpha');
      expect(
          (await get('/classic/login', using: private)).status, HttpStatus.ok);
    });
  });

  group('ui.mode ssr with the client', () {
    late App ssr;

    setUp(() {
      ssr = harness.buildApp(ui: _ssr);
    });

    test('the pages stay at / and the client is under /app', () async {
      final home = await get('/', using: ssr);
      expect(home.status, HttpStatus.ok);
      expect(home.body, contains('<title>Packages · unpub</title>'));
      expect(home.body, contains('action="/packages"'));

      for (final path in ['/app', '/app/', '/app/packages/alpha']) {
        final reply = await get(path, using: ssr);
        expectShell(reply, base: '/app');
        expect(reply.body, contains('<meta name="unpub-classic" content="">'));
      }
      final js = await get('/app$_script', html: false, using: ssr);
      expect(js.status, HttpStatus.ok);
      expect(js.headers['content-type'], startsWith('text/javascript'));
      expect((await get(_script, html: false, using: ssr)).status,
          HttpStatus.notFound);
    });

    test('readAccess authenticated keeps /app open', () async {
      final private =
          harness.buildApp(ui: _ssr, readAccess: ReadAccess.authenticated);
      expectShell(await get('/app/account', using: private), base: '/app');
      final home = await get('/', using: private);
      expect(home.status, HttpStatus.seeOther);
      expect(home.location, '/login');
    });
  });

  test('spa without a client cannot be built', () {
    expect(() => harness.buildApp(ui: const UiConfig(mode: UiMode.spa)),
        throwsArgumentError);
  });

  group('session of the client', () {
    test('the login cookie works for the whole site', () async {
      await harness.user('pub@example.com', Role.publisher);
      final secure = harness.buildApp(ui: _spa, secureCookies: true);
      final reply = await harness.send('POST', '/webapi/login',
          using: secure,
          json: {'email': 'pub@example.com', 'password': harnessPassword});
      expect(reply.status, HttpStatus.ok);
      final cookie = reply.headersAll['set-cookie']!
          .firstWhere((value) => value.startsWith('$sessionCookieName='));
      expect(cookie, contains('Path=/;'));
      expect(cookie, contains('HttpOnly'));
      expect(cookie, contains('SameSite=Lax'));
      expect(cookie, contains('Secure'));
      expect(reply.json['csrfToken'], isA<String>());
    });

    test('logout needs the CSRF header', () async {
      await harness.user('pub@example.com', Role.publisher);
      final browser = await harness.apiLogIn('pub@example.com');
      final refused = await harness.send('POST', '/webapi/logout',
          headers: {'cookie': '$sessionCookieName=${browser.cookie}'});
      expect(refused.status, HttpStatus.forbidden);
      expect(refused.json['error']['code'], 'csrf_failed');

      final done = await harness.send('POST', '/webapi/logout', headers: {
        'cookie': '$sessionCookieName=${browser.cookie}',
        'x-csrf-token': browser.csrf,
      });
      expect(done.status, HttpStatus.ok);
      expect(done.cookie(sessionCookieName), '');
      final me = await harness.send('GET', '/webapi/me',
          headers: {'cookie': '$sessionCookieName=${browser.cookie}'});
      expect(me.status, HttpStatus.unauthorized);
    });
  });
}
