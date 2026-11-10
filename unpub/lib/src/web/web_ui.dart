import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart' show IterableExtension;
import 'package:http_parser/http_parser.dart';
import 'package:logging/logging.dart';
import 'package:pub_semver/pub_semver.dart' as semver;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart';

import '../app.dart';
import '../auth/account_api.dart';
import '../auth/account_flows.dart';
import '../auth/account_service.dart';
import '../auth/accounts.dart';
import '../auth/auth_middleware.dart';
import '../auth/authenticator.dart';
import '../config/config.dart';
import '../http_cache.dart';
import '../models.dart';
import '../package_moderation.dart';
import '../routes/responses.dart' show parseVersionSegment;
import '../routes/route_support.dart';
import '../store/audit_store.dart';
import '../store/meta_store.dart';
import '../validation.dart';
import 'assets.dart';
import 'html.dart';
import 'layout.dart';
import 'pages/account_pages.dart';
import 'pages/admin_ops_pages.dart';
import 'pages/admin_pages.dart';
import 'pages/error_page.dart';
import 'pages/package_list_page.dart';
import 'pages/package_page.dart';
import 'settings.dart';

part 'web_ui_admin.dart';

final _log = Logger('unpub.web');

/// The policy sent with every page. Nothing inline is needed: the one script
/// and the one stylesheet are files, and markdown images may come from any
/// https host.
const contentSecurityPolicy = "default-src 'none'; script-src 'self'; "
    "style-src 'self'; img-src 'self' https: data:; connect-src 'self'; "
    "form-action 'self'; frame-ancestors 'none'; base-uri 'none'";

/// The headers every HTML response carries.
const securityHeaders = {
  'content-security-policy': contentSecurityPolicy,
  'x-content-type-options': 'nosniff',
  'referrer-policy': 'strict-origin-when-cross-origin',
  'x-frame-options': 'DENY',
};

/// The cookie holding the token the login form must echo, since there is no
/// session yet whose CSRF token could protect it.
const loginCookieName = 'unpub_login';
const _loginTokenField = 'login_token';

/// Largest form body read.
const _maxFormBytes = 64 * 1024;

/// Messages shown after a change that redirected back, by `done` code.
const _doneMessages = {
  'password-changed': 'Your password was changed.',
  'token-revoked': 'The token was revoked.',
  'user-created': 'The user was created.',
  'user-updated': 'The user was updated.',
  'password-set': 'The password was set.',
  'package-saved': 'The package was updated.',
  'version-retracted': 'The version was retracted.',
  'version-restored': 'The version was restored.',
  'uploader-added': 'The uploader was added.',
  'uploader-removed': 'The uploader was removed.',
};

/// Paths answered with JSON or files, never with a page.
bool _isApiPath(String path) {
  final trimmed = path.replaceFirst(RegExp(r'/+$'), '');
  return trimmed == 'healthz' ||
      trimmed == 'readyz' ||
      path == 'api' ||
      path.startsWith('api/') ||
      path == 'webapi' ||
      path.startsWith('webapi/') ||
      path.startsWith('badge/') ||
      path.startsWith('static/') ||
      path.endsWith('.tar.gz') ||
      path.endsWith('.json');
}

/// Whether [request] comes from a browser expecting a page.
bool wantsHtml(shelf.Request request) {
  if (_isApiPath(request.url.path)) return false;
  final accept = request.headers[HttpHeaders.acceptHeader] ?? '';
  return accept.contains('text/html');
}

/// A form submission that could not be read.
class _BadForm implements Exception {
  const _BadForm();
}

/// The server-side rendered web UI.
class WebUi {
  final App app;

  WebUi(this.app);

  late final _moderation = PackageModeration(app);

  late final _adminOps = _AdminOpsUi(this);

  AccountApi? get _accountApi => app.accountApi;

  void addRoutes(Router router) {
    // First, as they are more specific than the routes they share a prefix
    // with.
    _adminOps.addRoutes(router);
    router
      ..get('/', _guard(listPage))
      ..get('/packages', _guard(listPage))
      ..get('/packages/<name>', _guard1(showPackage))
      ..get('/packages/<name>/versions/<version>', _guard2(showVersion))
      ..get('/static/<file>', staticAsset)
      ..get('/login', _guard(loginForm))
      ..post('/login', _guard(login))
      ..post('/logout', _guard(logout))
      ..get('/account', _guard(account))
      ..post('/account/password', _guard(changePassword))
      ..post('/account/tokens', _guard(createToken))
      ..post('/account/tokens/<id>/revoke', _guard1(revokeToken))
      ..get('/admin', _guard(adminIndex))
      ..get('/admin/users', _guard(adminUsers))
      ..post('/admin/users', _guard(adminCreateUser))
      ..post('/admin/users/<id>', _guard1(adminUpdateUser))
      ..post('/admin/users/<id>/password', _guard1(adminSetPassword))
      ..get('/admin/packages', _guard(adminPackages))
      ..get('/admin/packages/<name>', _guard1(adminPackage))
      ..post('/admin/packages/<name>/discontinue', _guard1(adminDiscontinue))
      ..post('/admin/packages/<name>/versions/<version>/<action>',
          _guard3(adminRetraction))
      ..post('/admin/packages/<name>/uploaders', _guard1(adminAddUploader))
      ..post('/admin/packages/<name>/uploaders/remove',
          _guard1(adminRemoveUploader))
      ..get('/admin/settings', _guard(adminSettings));
  }

  // Responses.

  PageContext _context(shelf.Request req) => PageContext(
        principal: principalOf(req),
        path: req.requestedUri.path,
        query: req.url.path == 'packages' || req.url.path.isEmpty
            ? req.url.queryParameters['q']
            : null,
        accountsEnabled: _accountApi != null,
      );

  /// Headers of a page for [req]: a page shown to a signed-in user must not
  /// be kept by any cache.
  static Map<String, Object> pageHeaders(shelf.Request req) => {
        HttpHeaders.contentTypeHeader: 'text/html; charset=utf-8',
        HttpHeaders.cacheControlHeader:
            principalOf(req)?.session != null || sessionCookie(req) != null
                ? 'no-store'
                : 'private, max-age=0',
        ...securityHeaders,
      };

  static shelf.Response _html(shelf.Request req, Html document,
          {int status = HttpStatus.ok,
          Map<String, Object> headers = const {}}) =>
      shelf.Response(status,
          body: document.markup, headers: {...pageHeaders(req), ...headers});

  shelf.Response errorResponse(
      shelf.Request req, int status, String title, String message) {
    return _html(req, errorPage(_context(req), status, title, message),
        status: status);
  }

  shelf.Response _notFoundPage(shelf.Request req,
          [String message = 'There is nothing at this address.']) =>
      errorResponse(req, HttpStatus.notFound, 'Not found', message);

  shelf.Response _forbiddenPage(shelf.Request req, String message) =>
      errorResponse(req, HttpStatus.forbidden, 'Forbidden', message);

  static shelf.Response _redirect(String location) =>
      shelf.Response(HttpStatus.seeOther, headers: {
        HttpHeaders.locationHeader: location,
        HttpHeaders.cacheControlHeader: 'no-store',
      });

  /// Where a browser goes to log in and come back to [req].
  static String loginLocation(shelf.Request req) {
    final target = req.requestedUri;
    final back =
        target.hasQuery ? '${target.path}?${target.query}' : target.path;
    return back == '/'
        ? '/login'
        : '/login?${Uri(queryParameters: {'next': back}).query}';
  }

  /// The response to a failure of the auth middleware: pages for browsers,
  /// the JSON challenge for everything else.
  shelf.Response authFailure(shelf.Request req, AuthException error) {
    if (!wantsHtml(req)) return authFailureResponse(error);
    if (error.statusCode == HttpStatus.unauthorized) {
      final readMethod = req.method == 'GET' || req.method == 'HEAD';
      return _redirect(readMethod ? loginLocation(req) : '/login');
    }
    if (error.code == 'csrf_failed') {
      return _forbiddenPage(
          req,
          'The form was sent without a valid security token. Reload the page '
          'and try again.');
    }
    return _forbiddenPage(req, error.message);
  }

  /// The response for a path no route matched.
  shelf.Response notFound(shelf.Request req) {
    if (wantsHtml(req)) return _notFoundPage(req);
    return shelf.Response.notFound('Route not found');
  }

  /// Turns an error thrown while answering a browser into a page.
  shelf.Middleware get errorPages => (inner) => (req) async {
        try {
          return await inner(req);
        } on shelf.HijackException {
          rethrow;
        } catch (error, stackTrace) {
          if (!wantsHtml(req)) rethrow;
          _log.severe('error answering ${req.method} ${req.requestedUri.path}',
              error, stackTrace);
          return errorResponse(
              req,
              HttpStatus.internalServerError,
              'Something went wrong',
              'The server could not answer. Try again later.');
        }
      };

  /// Shows the refusals routes throw as pages.
  Future<shelf.Response> _reporting(
      shelf.Request req, Future<shelf.Response> Function() route) async {
    try {
      return await route();
    } on AuthException catch (error) {
      if (error.statusCode == HttpStatus.unauthorized) {
        return _redirect(loginLocation(req));
      }
      return _forbiddenPage(req, error.message);
    } on AccountException catch (error) {
      return errorResponse(
          req, error.statusCode, 'Not possible', error.message);
    } on ModerationException catch (error) {
      return errorResponse(
          req, error.statusCode, 'Not possible', error.message);
    } on _BadForm {
      return errorResponse(req, HttpStatus.badRequest, 'Bad request',
          'The form could not be read.');
    }
  }

  shelf.Handler _guard(Future<shelf.Response> Function(shelf.Request) route) =>
      (req) => _reporting(req, () => route(req));

  Function _guard1(
          Future<shelf.Response> Function(shelf.Request, String) route) =>
      (shelf.Request req, String a) => _reporting(req, () => route(req, a));

  Function _guard2(
          Future<shelf.Response> Function(shelf.Request, String, String)
              route) =>
      (shelf.Request req, String a, String b) =>
          _reporting(req, () => route(req, a, b));

  Function _guard3(
          Future<shelf.Response> Function(shelf.Request, String, String, String)
              route) =>
      (shelf.Request req, String a, String b, String c) =>
          _reporting(req, () => route(req, a, b, c));

  /// The fields of a form post, each with every value it was given.
  static Future<Map<String, List<String>>> _form(shelf.Request req) async {
    final contentType = req.headers[HttpHeaders.contentTypeHeader];
    try {
      if (contentType == null ||
          MediaType.parse(contentType).mimeType !=
              'application/x-www-form-urlencoded') {
        throw const _BadForm();
      }
    } on FormatException {
      throw const _BadForm();
    }
    final bytes = <int>[];
    await for (final chunk in req.read()) {
      bytes.addAll(chunk);
      if (bytes.length > _maxFormBytes) throw const _BadForm();
    }
    try {
      return Uri(query: utf8.decode(bytes)).queryParametersAll;
    } on FormatException {
      throw const _BadForm();
    }
  }

  static String? _field(Map<String, List<String>> form, String name) {
    final value = form[name]?.firstOrNull?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  // Static files.

  Future<shelf.Response> staticAsset(shelf.Request req, String file) async {
    final asset = staticAssets[file];
    if (asset == null) return shelf.Response.notFound('Not found');
    final headers = {
      HttpHeaders.contentTypeHeader: asset.contentType,
      HttpHeaders.cacheControlHeader: 'public, max-age=31536000, immutable',
      HttpHeaders.etagHeader: asset.etag,
      'x-content-type-options': 'nosniff',
    };
    if (etagMatches(req.headers[HttpHeaders.ifNoneMatchHeader], asset.etag)) {
      return shelf.Response.notModified(headers: headers);
    }
    return shelf.Response.ok(asset.bytes, headers: headers);
  }

  // Packages.

  Future<shelf.Response> listPage(shelf.Request req) async {
    final query = req.url.queryParameters;
    final request = PackageListRequest.fromQuery(query);
    final result = await app.metaStore.searchPackages(request.search);
    if (query['partial'] == '1') {
      return _html(req, packageResults(request, result));
    }
    return _html(req, packageListPage(_context(req), request, result));
  }

  String _hostedUrl(shelf.Request req) {
    final root = app.resolveUrl(req, '/');
    return root.endsWith('/') ? root.substring(0, root.length - 1) : root;
  }

  Uri get _upstream => Uri.parse(app.upstream);

  /// The page for a package this server does not have: the upstream's page
  /// for one this server proxies, otherwise a 404.
  shelf.Response _unknownPackage(shelf.Request req, String name) {
    final proxy = app.upstreamProxy;
    if (proxy != null && proxy.allows(name)) {
      return shelf.Response.found(_upstream
          .resolve('/packages/${Uri.encodeComponent(name)}')
          .toString());
    }
    return _html(
        req,
        errorPage(_context(req), HttpStatus.notFound, 'Package not found',
            'There is no package $name on this server.',
            extra: el('p', const {}, [
              el(
                  'a',
                  {
                    'href': _upstream
                        .resolve('/packages/${Uri.encodeComponent(name)}')
                        .toString(),
                    'rel': 'noopener',
                  },
                  'Look for $name on ${_upstream.host}'),
            ])),
        status: HttpStatus.notFound);
  }

  Future<shelf.Response> showPackage(shelf.Request req, String name) =>
      _packagePage(req, name, null);

  Future<shelf.Response> showVersion(
      shelf.Request req, String name, String version) async {
    final decoded = parseVersionSegment(version);
    if (decoded == null) return _notFoundPage(req);
    return _packagePage(req, name, decoded);
  }

  Future<shelf.Response> _packagePage(
      shelf.Request req, String name, String? versionName) async {
    if (!isValidPackageName(name)) return _notFoundPage(req);
    final package = await app.metaStore.queryPackage(name);
    if (package == null) return _unknownPackage(req, name);

    final UnpubVersion version;
    if (versionName == null) {
      version = package.latest;
    } else {
      final found = package.versions
          .firstWhereOrNull((item) => item.version == versionName);
      if (found == null) {
        return _notFoundPage(req, '$name has no version $versionName.');
      }
      version = found;
    }

    final tab = PackageTab.parse(req.url.queryParameters['tab']);
    final versions = [...package.versions]
      ..sort((a, b) => _compareVersions(b.version, a.version));
    final dependencies = [
      for (final item
          in (version.pubspec['dependencies'] as Map? ?? const {}).keys)
        if (item is String && isValidPackageName(item)) item,
    ];
    final view = PackageView(
      package: package,
      version: version,
      versionPage: versionName != null,
      versions: versions,
      versionDownloads: tab == PackageTab.versions
          ? await app.metaStore
              .versionDownloadCounts(name, versions.map((item) => item.version))
          : const {},
      localPackages: await app.metaStore.existingPackageNames(dependencies),
      tab: tab,
      hostedUrl: _hostedUrl(req),
      upstream: _upstream,
      authenticatedReads: app.readAccess == ReadAccess.authenticated,
    );
    return _html(req, packagePage(_context(req), view));
  }

  static int _compareVersions(String a, String b) {
    try {
      return semver.Version.parse(a).compareTo(semver.Version.parse(b));
    } on FormatException {
      return a.compareTo(b);
    }
  }

  // Login.

  /// Where to go after logging in: a path on this server, never another
  /// origin.
  static String? safeNext(String? next) {
    if (next == null || next.isEmpty || next.length > 2048) return null;
    if (!next.startsWith('/') || next.startsWith('//')) return null;
    if (next.contains('\\') || next.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      return null;
    }
    final uri = Uri.tryParse(next);
    if (uri == null || uri.hasScheme || uri.hasAuthority) return null;
    if (uri.path == '/login') return null;
    return next;
  }

  String _loginCookie(String value, {bool clear = false}) =>
      '$loginCookieName=${clear ? '' : value}; Path=/login; HttpOnly; '
      'SameSite=Strict; Max-Age=${clear ? 0 : 3600}'
      '${_accountApi?.secureCookies ?? false ? '; Secure' : ''}';

  static String? _cookie(shelf.Request req, String name) {
    final header = req.headers[HttpHeaders.cookieHeader];
    if (header == null) return null;
    for (final pair in header.split(';')) {
      final separator = pair.indexOf('=');
      if (separator < 0) continue;
      if (pair.substring(0, separator).trim() == name) {
        final value = pair.substring(separator + 1).trim();
        return value.isEmpty ? null : value;
      }
    }
    return null;
  }

  /// The login form, with a fresh token for it in a cookie.
  shelf.Response _loginForm(shelf.Request req,
      {String? next,
      String? email,
      String? error,
      int status = HttpStatus.ok,
      Map<String, Object> headers = const {}}) {
    final token = generateSecret();
    return _html(
      req,
      loginPage(_context(req),
          loginToken: token, next: next, email: email, error: error),
      status: status,
      headers: {HttpHeaders.setCookieHeader: _loginCookie(token), ...headers},
    );
  }

  Future<shelf.Response> loginForm(shelf.Request req) async {
    if (_accountApi == null) {
      return _notFoundPage(req, 'This server has no user accounts.');
    }
    final next = safeNext(req.url.queryParameters['next']);
    if (principalOf(req)?.session != null) return _redirect(next ?? '/');
    return _loginForm(req, next: next);
  }

  Future<shelf.Response> login(shelf.Request req) async {
    final api = _accountApi;
    if (api == null) {
      return _notFoundPage(req, 'This server has no user accounts.');
    }
    final form = await _form(req);
    final next = safeNext(_field(form, 'next'));
    final email = normalizeEmail(_field(form, 'email') ?? '');
    final password = form['password']?.firstOrNull ?? '';

    final expected = _cookie(req, loginCookieName);
    final presented = _field(form, _loginTokenField);
    if (expected == null ||
        presented == null ||
        !constantTimeEquals(expected, presented)) {
      return _loginForm(req,
          next: next,
          email: email.isEmpty ? null : email,
          error: 'The login form expired. Please try again.',
          status: HttpStatus.forbidden);
    }

    const rejected = 'Invalid email or password.';
    if (!isValidEmail(email) || password.isEmpty) {
      return _loginForm(req,
          next: next,
          email: email.isEmpty ? null : email,
          error: rejected,
          status: HttpStatus.unauthorized);
    }

    final outcome = await attemptLogin(
      api.accounts,
      api.limiter,
      email: email,
      password: password,
      address: clientAddress(req, trustForwardedFor: api.trustForwardedFor),
      previousCookie: sessionCookie(req),
    );
    switch (outcome) {
      case LoggedIn(:final result):
        return shelf.Response(HttpStatus.seeOther, headers: {
          HttpHeaders.locationHeader: next ?? '/',
          HttpHeaders.cacheControlHeader: 'no-store',
          HttpHeaders.setCookieHeader: [
            sessionCookieHeader(result.cookieValue, secure: api.secureCookies),
            _loginCookie('', clear: true),
          ],
        });
      case Throttled(:final wait):
        return _loginForm(req,
            next: next,
            email: email,
            error: 'Too many failed attempts. Try again later.',
            status: HttpStatus.tooManyRequests,
            headers: {HttpHeaders.retryAfterHeader: '${wait.inSeconds + 1}'});
      default:
        return _loginForm(req,
            next: next,
            email: email,
            error: rejected,
            status: HttpStatus.unauthorized);
    }
  }

  Future<shelf.Response> logout(shelf.Request req) async {
    final api = _accountApi;
    final cookie = sessionCookie(req);
    if (api != null && cookie != null) await api.accounts.logout(cookie);
    return shelf.Response(HttpStatus.seeOther, headers: {
      HttpHeaders.locationHeader: '/',
      HttpHeaders.cacheControlHeader: 'no-store',
      HttpHeaders.setCookieHeader:
          clearedSessionCookieHeader(secure: api?.secureCookies ?? false),
    });
  }

  // Own account.

  /// The account service, and the principal of a password session.
  ///
  /// Pages that change credentials accept nothing else, as the JSON API.
  (AccountApi, Principal) _session(shelf.Request req) {
    final api = _accountApi;
    if (api == null) {
      throw const AccountException.notFound(
          'This server has no user accounts.');
    }
    final principal = principalOf(req);
    if (principal == null) {
      throw const AuthException.unauthorized('Log in to see this page.');
    }
    requirePasswordSession(principal);
    return (api, principal);
  }

  AuditContext _by(shelf.Request req, AccountApi api, Principal principal) =>
      AuditContext.of(principal,
          ip: clientAddress(req, trustForwardedFor: api.trustForwardedFor));

  Future<shelf.Response> _accountPage(
    shelf.Request req,
    AccountApi api,
    Principal principal, {
    CreatedToken? created,
    String? notice,
    String? error,
    int status = HttpStatus.ok,
  }) async {
    final user = await api.accounts.requireUserById(principal.userId!);
    final tokens = await api.accounts.store.listTokens(user.id);
    tokens.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return _html(
      req,
      accountPage(
        _context(req),
        AccountView(
          user: user,
          tokens: tokens,
          grantableScopes:
              principal.scopes.intersection(scopesAllowedFor(user.role)),
          created: created,
          hostedUrl: _hostedUrl(req),
          now: api.accounts.clock(),
          notice: notice,
          error: error,
        ),
      ),
      status: status,
    );
  }

  Future<shelf.Response> account(shelf.Request req) async {
    final (api, principal) = _session(req);
    return _accountPage(req, api, principal,
        notice: _doneMessages[req.url.queryParameters['done']]);
  }

  Future<shelf.Response> changePassword(shelf.Request req) async {
    final (api, principal) = _session(req);
    final form = await _form(req);
    final user = await api.accounts.requireUserById(principal.userId!);
    try {
      final outcome = await changeOwnPassword(
        api.accounts,
        api.limiter,
        user: user,
        current: form['currentPassword']?.firstOrNull ?? '',
        replacement: form['newPassword']?.firstOrNull ?? '',
        address: clientAddress(req, trustForwardedFor: api.trustForwardedFor),
        by: _by(req, api, principal),
        keepSessionId: principal.session?.id,
      );
      return switch (outcome) {
        PasswordChanged() => _redirect('/account?done=password-changed'),
        Throttled() => await _accountPage(req, api, principal,
            error: 'Too many failed attempts. Try again later.',
            status: HttpStatus.tooManyRequests),
        _ => await _accountPage(req, api, principal,
            error: 'The current password is wrong.',
            status: HttpStatus.forbidden),
      };
    } on AccountException catch (error) {
      return _accountPage(req, api, principal,
          error: _sentence(error.message), status: error.statusCode);
    }
  }

  Future<shelf.Response> createToken(shelf.Request req) async {
    final (api, principal) = _session(req);
    final form = await _form(req);
    final user = await api.accounts.requireUserById(principal.userId!);
    try {
      final created = await api.accounts.createToken(
        user,
        name: _field(form, 'name') ?? '',
        scopes: requestedScopes(form['scope'] ?? const [], principal, user),
        expiresAt: requestedExpiry(
            _field(form, 'expiresIn'), principal, api.accounts.clock()),
        by: _by(req, api, principal),
      );
      return await _accountPage(req, api, principal,
          created: created, status: HttpStatus.created);
    } on AccountException catch (error) {
      return _accountPage(req, api, principal,
          error: _sentence(error.message), status: error.statusCode);
    }
  }

  Future<shelf.Response> revokeToken(shelf.Request req, String id) async {
    final (api, principal) = _session(req);
    final token = await api.accounts.store.findTokenById(id);
    // Only the own tokens can be revoked here, someone else's is absent.
    if (token == null || token.userId != principal.userId) {
      return _notFoundPage(req, 'There is no such token.');
    }
    await api.accounts.revokeToken(token, by: _by(req, api, principal));
    return _redirect('/account?done=token-revoked');
  }

  // Administration.

  /// The principal of an administrator with a password session, refusing
  /// everyone else.
  ///
  /// The pages show users, settings and packages whatever the scopes of a
  /// token, so no token opens them, as no token changes credentials or roles.
  Principal _administrator(shelf.Request req) {
    final principal = principalOf(req);
    if (principal == null) {
      throw const AuthException.unauthorized('Log in to see this page.');
    }
    if (!principal.isAdmin) {
      throw const AuthException.forbidden(
          'Only administrators can see this page.');
    }
    if (principal.credentialKind != CredentialKind.session) {
      throw const AuthException.forbidden(
          'Log in with a password to see this page. API tokens cannot open '
          'the administration pages.',
          code: 'session_required');
    }
    return principal;
  }

  AccountApi _requireAccounts() {
    final api = _accountApi;
    if (api == null) {
      throw const AccountException.notFound(
          'This server has no user accounts.');
    }
    return api;
  }

  Future<shelf.Response> _usersPage(shelf.Request req, AccountApi api,
      {String? notice, String? error, int status = HttpStatus.ok}) async {
    final users = await api.accounts.store.listUsers();
    return _html(
        req, adminUsersPage(_context(req), users, notice: notice, error: error),
        status: status);
  }

  Future<shelf.Response> adminUsers(shelf.Request req) async {
    _administrator(req);
    final api = _requireAccounts();
    return _usersPage(req, api,
        notice: _doneMessages[req.url.queryParameters['done']]);
  }

  Future<shelf.Response> _changingUsers(
      shelf.Request req,
      Future<String> Function(AccountApi, Principal, Map<String, List<String>>)
          change) async {
    final principal = _administrator(req);
    final api = _requireAccounts();
    final form = await _form(req);
    try {
      final done = await change(api, principal, form);
      return _redirect('/admin/users?done=$done');
    } on AccountException catch (error) {
      return _usersPage(req, api,
          error: _sentence(error.message), status: error.statusCode);
    }
  }

  Future<shelf.Response> adminCreateUser(shelf.Request req) =>
      _changingUsers(req, (api, principal, form) async {
        final role = Role.tryParse(_field(form, 'role'));
        if (role == null) {
          throw const AccountException.invalid(
              'role must be one of admin, publisher, reader');
        }
        await api.accounts.createUser(
          email: _field(form, 'email') ?? '',
          role: role,
          displayName: _field(form, 'displayName'),
          password: form['password']?.firstOrNull?.isEmpty ?? true
              ? null
              : form['password']!.first,
          by: _by(req, api, principal),
        );
        return 'user-created';
      });

  Future<shelf.Response> adminUpdateUser(shelf.Request req, String id) =>
      _changingUsers(req, (api, principal, form) async {
        final roleName = _field(form, 'role');
        final role = roleName == null ? null : Role.tryParse(roleName);
        if (roleName != null && role == null) {
          throw const AccountException.invalid(
              'role must be one of admin, publisher, reader');
        }
        final disabled = switch (_field(form, 'disabled')) {
          null => null,
          'true' => true,
          'false' => false,
          _ => throw const AccountException.invalid(
              'disabled must be true or false'),
        };
        final user = await api.accounts.requireUserById(id);
        await api.accounts.updateUser(
          user,
          displayName: _field(form, 'displayName'),
          role: role,
          disabled: disabled,
          by: _by(req, api, principal),
        );
        return 'user-updated';
      });

  Future<shelf.Response> adminSetPassword(shelf.Request req, String id) =>
      _changingUsers(req, (api, principal, form) async {
        final user = await api.accounts.requireUserById(id);
        await api.accounts.setPassword(
            user, form['password']?.firstOrNull ?? '',
            by: _by(req, api, principal));
        return 'password-set';
      });

  Future<shelf.Response> adminPackages(shelf.Request req) async {
    _administrator(req);
    // Every package by name, with the search and paging of the list.
    final list = PackageListRequest.fromQuery({
      ...req.url.queryParameters,
      'size': req.url.queryParameters['size'] ?? '$maxPageSize',
    });
    final result = await app.metaStore.searchPackages(PackageSearch(
      text: list.query,
      includeDiscontinued: true,
      sort: PackageSort.name,
      page: list.page - 1,
      size: list.size,
    ));
    return _html(
        req,
        adminPackagesPage(_context(req), list.query, result,
            page: list.page, size: list.size));
  }

  Future<shelf.Response> _adminPackagePage(shelf.Request req, String name,
      {String? notice, String? error, int status = HttpStatus.ok}) async {
    final package = isValidPackageName(name)
        ? await app.metaStore.queryPackage(name)
        : null;
    if (package == null) {
      return _notFoundPage(req, 'There is no package $name on this server.');
    }
    final versions = [...package.versions]
      ..sort((a, b) => _compareVersions(b.version, a.version));
    return _html(
        req,
        adminPackagePage(_context(req), package, versions,
            notice: notice, error: error),
        status: status);
  }

  Future<shelf.Response> adminPackage(shelf.Request req, String name) async {
    _administrator(req);
    return _adminPackagePage(req, name,
        notice: _doneMessages[req.url.queryParameters['done']]);
  }

  /// Runs a [change] of the package [name] and goes back to its page.
  Future<shelf.Response> _changingPackage(
      shelf.Request req,
      String name,
      Future<String> Function(Principal, Map<String, List<String>>)
          change) async {
    final principal = _administrator(req);
    if (!isValidPackageName(name)) return _notFoundPage(req);
    final form = await _form(req);
    try {
      final done = await change(principal, form);
      return _redirect('/admin/packages/${segment(name)}?done=$done');
    } on ModerationException catch (error) {
      if (error.statusCode == HttpStatus.notFound &&
          await app.metaStore.queryPackage(name) == null) {
        return _notFoundPage(req, 'There is no package $name on this server.');
      }
      return _adminPackagePage(req, name,
          error: _sentence(error.message), status: error.statusCode);
    }
  }

  Future<shelf.Response> adminDiscontinue(shelf.Request req, String name) =>
      _changingPackage(req, name, (principal, form) async {
        final discontinued = _field(form, 'discontinued') == '1';
        final replacedBy = _field(form, 'replacedBy');
        await _moderation.setDiscontinued(req, principal, name,
            discontinued: discontinued,
            replacedBy: discontinued ? replacedBy : null);
        return 'package-saved';
      });

  /// Where the administration starts, for an administrator only.
  Future<shelf.Response> adminIndex(shelf.Request req) async {
    _administrator(req);
    return _redirect('/admin/users');
  }

  Future<shelf.Response> adminRetraction(
      shelf.Request req, String name, String version, String action) async {
    _administrator(req);
    final retracted = switch (action) {
      'retract' => true,
      'unretract' => false,
      _ => null,
    };
    final decoded = parseVersionSegment(version);
    if (retracted == null || decoded == null) return _notFoundPage(req);
    return _changingPackage(req, name, (principal, form) async {
      await _moderation.setRetracted(req, principal, name, decoded,
          retracted: retracted);
      return retracted ? 'version-retracted' : 'version-restored';
    });
  }

  Future<shelf.Response> adminAddUploader(shelf.Request req, String name) =>
      _changingPackage(req, name, (principal, form) async {
        final email = normalizeEmail(_field(form, 'email') ?? '');
        if (email.isEmpty) {
          throw const ModerationException.invalid('email is required');
        }
        if (!isValidEmail(email)) {
          throw const ModerationException.invalid('email is invalid');
        }
        await _moderation.addUploader(req, principal, name, email);
        return 'uploader-added';
      });

  Future<shelf.Response> adminRemoveUploader(shelf.Request req, String name) =>
      _changingPackage(req, name, (principal, form) async {
        await _moderation.removeUploader(
            req, principal, name, _field(form, 'email') ?? '');
        return 'uploader-removed';
      });

  Future<shelf.Response> adminSettings(shelf.Request req) async {
    _administrator(req);
    final config = app.config;
    return _html(
        req,
        adminSettingsPage(
            _context(req), config == null ? null : settingsOverview(config)));
  }

  /// [message] from a service, which starts lowercase, as a sentence.
  static String _sentence(String message) {
    if (message.isEmpty) return message;
    final text = '${message[0].toUpperCase()}${message.substring(1)}';
    return text.endsWith('.') ? text : '$text.';
  }
}
