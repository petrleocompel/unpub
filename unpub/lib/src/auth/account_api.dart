import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart';

import 'account_service.dart';
import 'accounts.dart';
import 'auth_middleware.dart';
import 'authenticator.dart';
import 'rate_limiter.dart';

/// Largest JSON body accepted, far above any legitimate request.
const _maxJsonBytes = 64 * 1024;

/// The JSON account endpoints under `/webapi`.
///
/// Errors have the form `{"error": {"code": ..., "message": ...}}`.
class AccountApi {
  final AccountService accounts;
  final LoginRateLimiter limiter;

  /// Whether cookies are marked `Secure`, set when served over HTTPS.
  final bool secureCookies;
  final bool trustForwardedFor;

  AccountApi(
    this.accounts, {
    required this.limiter,
    this.secureCookies = false,
    this.trustForwardedFor = false,
  });

  void addRoutes(Router router) {
    router
      ..post('/webapi/login', _guarded(_login))
      ..post('/webapi/logout', _guarded(_logout))
      ..get('/webapi/me', _guarded(_me))
      ..post('/webapi/me/password', _guarded(_changeOwnPassword))
      ..get('/webapi/tokens', _guarded(_listTokens))
      ..post('/webapi/tokens', _guarded(_createToken))
      ..delete('/webapi/tokens/<id>', _guardedWithId(_revokeToken))
      ..get('/webapi/users', _guarded(_listUsers))
      ..post('/webapi/users', _guarded(_createUser))
      ..patch('/webapi/users/<id>', _guardedWithId(_updateUser))
      ..post('/webapi/users/<id>/password', _guardedWithId(_setUserPassword));
  }

  shelf.Handler _guarded(Future<shelf.Response> Function(shelf.Request) route) {
    return (request) => _reportingFailures(() => route(request));
  }

  Function _guardedWithId(
      Future<shelf.Response> Function(shelf.Request, String) route) {
    return (shelf.Request request, String id) =>
        _reportingFailures(() => route(request, id));
  }

  Future<shelf.Response> _reportingFailures(
      Future<shelf.Response> Function() route) async {
    try {
      return await route();
    } on AuthException catch (error) {
      return authFailureResponse(error);
    } on AccountException catch (error) {
      return _error(error.statusCode, error.code, error.message);
    }
  }

  static shelf.Response _json(
    int status,
    Map<String, Object?> body, {
    Map<String, String> headers = const {},
  }) =>
      shelf.Response(
        status,
        body: json.encode(body),
        headers: {
          HttpHeaders.contentTypeHeader: ContentType.json.mimeType,
          HttpHeaders.cacheControlHeader: 'no-store',
          ...headers,
        },
      );

  static shelf.Response _error(
    int status,
    String code,
    String message, {
    Map<String, String> headers = const {},
  }) =>
      _json(
          status,
          {
            'error': {'code': code, 'message': message},
          },
          headers: headers);

  static Future<Map<String, dynamic>> _readJson(shelf.Request request) async {
    final contentType = request.headers[HttpHeaders.contentTypeHeader] ?? '';
    if (!contentType.toLowerCase().startsWith(ContentType.json.mimeType)) {
      throw const AccountException.invalid(
          'the content type must be application/json');
    }
    final bytes = <int>[];
    await for (final chunk in request.read()) {
      bytes.addAll(chunk);
      if (bytes.length > _maxJsonBytes) {
        throw const AccountException.invalid('the body is too large');
      }
    }
    try {
      final body = json.decode(utf8.decode(bytes));
      if (body is Map<String, dynamic>) return body;
    } on FormatException {
      // Reported below.
    }
    throw const AccountException.invalid('the body must be a JSON object');
  }

  static String _requiredString(Map<String, dynamic> body, String key) {
    final value = body[key];
    if (value is String && value.isNotEmpty) return value;
    throw AccountException.invalid('$key is required');
  }

  static String? _optionalString(Map<String, dynamic> body, String key) {
    final value = body[key];
    if (value == null || value is String) return value as String?;
    throw AccountException.invalid('$key must be a string');
  }

  static Role? _optionalRole(Map<String, dynamic> body) {
    if (body['role'] == null) return null;
    final role = Role.tryParse(body['role']);
    if (role == null) {
      throw const AccountException.invalid(
          'role must be one of admin, publisher, reader');
    }
    return role;
  }

  String? _address(shelf.Request request) =>
      clientAddress(request, trustForwardedFor: trustForwardedFor);

  AuditContext _by(shelf.Request request, Principal principal) =>
      AuditContext(principal.actor,
          ip: _address(request), kind: principal.credentialKind.name);

  static Principal _principal(shelf.Request request) {
    final principal = principalOf(request);
    if (principal == null) {
      throw const AuthException.unauthorized('Authentication is required.');
    }
    return principal;
  }

  static Principal _admin(shelf.Request request) {
    final principal = _principal(request);
    if (!principal.isAdmin) {
      throw const AuthException.forbidden('Administrator role required.');
    }
    return principal;
  }

  /// Rejects everything except a password login.
  ///
  /// Changing credentials or roles would let a narrowed or expiring token
  /// trade itself for full access, so no token may do it. The command line
  /// goes through [AccountService] directly and is not affected.
  static Principal _requireSession(Principal principal) {
    if (principal.credentialKind != CredentialKind.session) {
      throw const AuthException.forbidden(
          'Log in with a password to do this. API tokens cannot change '
          'credentials or roles.',
          code: 'session_required');
    }
    return principal;
  }

  /// Rejects a token that was not granted [Scope.read].
  static void _requireRead(Principal principal) {
    if (!principal.scopes.contains(Scope.read)) {
      throw const AuthException.forbidden('This token cannot read.',
          code: 'insufficient_scope');
    }
  }

  Future<User> _account(Principal principal) async {
    final id = principal.userId;
    if (id == null) {
      throw const AccountException.forbidden(
          'A static token from the configuration has no account.');
    }
    return accounts.requireUserById(id);
  }

  String _setSessionCookie(String value) => '$sessionCookieName=$value; '
      'Path=/; HttpOnly; SameSite=Lax; Max-Age=${sessionLifetime.inSeconds}'
      '${secureCookies ? '; Secure' : ''}';

  String get _clearSessionCookie => '$sessionCookieName=; '
      'Path=/; HttpOnly; SameSite=Lax; Max-Age=0'
      '${secureCookies ? '; Secure' : ''}';

  static shelf.Response _tooManyAttempts(Duration wait) => _error(
        HttpStatus.tooManyRequests,
        'rate_limited',
        'Too many failed attempts. Try again later.',
        headers: {
          HttpHeaders.retryAfterHeader: '${wait.inSeconds + 1}',
        },
      );

  Future<shelf.Response> _login(shelf.Request request) async {
    final body = await _readJson(request);
    final email = normalizeEmail(_requiredString(body, 'email'));
    final password = _requiredString(body, 'password');
    if (!isValidEmail(email)) {
      throw const AccountException.invalid('email is invalid');
    }

    final address = _address(request);
    final wait = limiter.acquire(address, email);
    if (wait != null) return _tooManyAttempts(wait);

    final result =
        await accounts.login(email: email, password: password, ip: address);
    if (result == null) {
      return _error(HttpStatus.unauthorized, 'invalid_credentials',
          'Invalid email or password.');
    }
    limiter.succeeded(address, email);

    // A new login replaces whatever session this browser held before.
    final previous = sessionCookie(request);
    if (previous != null) await accounts.logout(previous);

    return _json(
      HttpStatus.ok,
      {'user': result.user.toJson(), 'csrfToken': result.session.csrfToken},
      headers: {
        HttpHeaders.setCookieHeader: _setSessionCookie(result.cookieValue),
      },
    );
  }

  Future<shelf.Response> _logout(shelf.Request request) async {
    _principal(request);
    final cookie = sessionCookie(request);
    if (cookie != null) await accounts.logout(cookie);
    return _json(
      HttpStatus.ok,
      {'success': true},
      headers: {HttpHeaders.setCookieHeader: _clearSessionCookie},
    );
  }

  Future<shelf.Response> _me(shelf.Request request) async {
    final principal = _principal(request);
    final id = principal.userId;
    return _json(HttpStatus.ok, {
      'user': id == null
          ? {'id': null, 'email': principal.email, 'role': principal.role.name}
          : (await accounts.requireUserById(id)).toJson(),
      'scopes': [for (final scope in principal.scopes) scope.name],
      if (principal.session != null) 'csrfToken': principal.session!.csrfToken,
    });
  }

  Future<shelf.Response> _changeOwnPassword(shelf.Request request) async {
    final principal = _requireSession(_principal(request));
    final user = await _account(principal);
    final body = await _readJson(request);
    final current = _requiredString(body, 'currentPassword');
    final replacement = _requiredString(body, 'newPassword');

    final address = _address(request);
    final wait = limiter.acquire(address, user.email);
    if (wait != null) return _tooManyAttempts(wait);
    if (!await accounts.verifyPassword(user, current)) {
      return _error(HttpStatus.forbidden, 'invalid_credentials',
          'The current password is wrong.');
    }
    limiter.succeeded(address, user.email);

    await accounts.setPassword(
      user,
      replacement,
      by: _by(request, principal),
      keepSessionId: principal.session?.id,
    );
    return _json(HttpStatus.ok, {'success': true});
  }

  Future<shelf.Response> _listTokens(shelf.Request request) async {
    final principal = _principal(request);
    _requireRead(principal);
    final user = await _account(principal);
    final tokens = await accounts.store.listTokens(user.id);
    return _json(HttpStatus.ok, {
      'tokens': [for (final token in tokens) token.toJson()],
    });
  }

  /// Validates the requested scopes. A token cannot create a token that can
  /// do more than itself.
  static Set<Scope>? _requestedScopes(
      Map<String, dynamic> body, Principal principal, User user) {
    final raw = body['scopes'];
    if (raw == null) {
      return principal.scopes.intersection(scopesAllowedFor(user.role));
    }
    if (raw is! List) {
      throw const AccountException.invalid('scopes must be a list');
    }
    final scopes = <Scope>{};
    for (final name in raw) {
      final scope = Scope.tryParse(name);
      if (scope == null) {
        throw const AccountException.invalid(
            'scopes may only contain read and publish');
      }
      scopes.add(scope);
    }
    if (!principal.scopes.containsAll(scopes)) {
      throw const AccountException.forbidden(
          'a token cannot grant scopes it does not hold');
    }
    return scopes;
  }

  /// The expiry of a new token. A token cannot outlive the one creating it.
  DateTime? _requestedExpiry(Map<String, dynamic> body, Principal principal) {
    final text = _optionalString(body, 'expiresIn');
    DateTime? expiresAt;
    if (text != null) {
      final duration = parseDuration(text);
      if (duration == null) {
        throw const AccountException.invalid(
            'expiresIn must look like 12h, 30d or 8w');
      }
      expiresAt = accounts.clock().add(duration);
    }
    final limit = principal.tokenExpiresAt;
    if (limit == null) return expiresAt;
    if (expiresAt == null) return limit;
    if (expiresAt.isAfter(limit)) {
      throw const AccountException.invalid(
          'a token cannot outlive the token creating it');
    }
    return expiresAt;
  }

  Future<shelf.Response> _createToken(shelf.Request request) async {
    final principal = _principal(request);
    final user = await _account(principal);
    final body = await _readJson(request);
    final created = await accounts.createToken(
      user,
      name: _requiredString(body, 'name'),
      scopes: _requestedScopes(body, principal, user),
      expiresAt: _requestedExpiry(body, principal),
      by: _by(request, principal),
    );
    return _json(HttpStatus.created, {
      'token': created.token.toJson(),
      'secret': created.secret,
    });
  }

  Future<shelf.Response> _revokeToken(shelf.Request request, String id) async {
    final principal = _principal(request);
    final token = await accounts.store.findTokenById(id);
    if (token == null) throw const AccountException.notFound('no such token');
    if (token.userId != principal.userId) {
      // Someone else's token is reported as absent, not as forbidden.
      if (!principal.isAdmin) {
        throw const AccountException.notFound('no such token');
      }
      // A leaked or narrowed token must not be able to lock other people out.
      _requireSession(principal);
    }
    await accounts.revokeToken(token, by: _by(request, principal));
    final revoked = await accounts.store.findTokenById(id);
    return _json(HttpStatus.ok, {'token': revoked!.toJson()});
  }

  Future<shelf.Response> _listUsers(shelf.Request request) async {
    _requireRead(_admin(request));
    final users = await accounts.store.listUsers();
    return _json(HttpStatus.ok, {
      'users': [for (final user in users) user.toJson()],
    });
  }

  Future<shelf.Response> _createUser(shelf.Request request) async {
    final principal = _requireSession(_admin(request));
    final body = await _readJson(request);
    final role = _optionalRole(body);
    if (role == null) {
      throw const AccountException.invalid('role is required');
    }
    final user = await accounts.createUser(
      email: _requiredString(body, 'email'),
      role: role,
      displayName: _optionalString(body, 'displayName'),
      password: _optionalString(body, 'password'),
      by: _by(request, principal),
    );
    return _json(HttpStatus.created, {'user': user.toJson()});
  }

  Future<shelf.Response> _updateUser(shelf.Request request, String id) async {
    final principal = _requireSession(_admin(request));
    final body = await _readJson(request);
    final disabled = body['disabled'];
    if (disabled != null && disabled is! bool) {
      throw const AccountException.invalid('disabled must be true or false');
    }
    final user = await accounts.requireUserById(id);
    final updated = await accounts.updateUser(
      user,
      displayName: _optionalString(body, 'displayName'),
      role: _optionalRole(body),
      disabled: disabled as bool?,
      by: _by(request, principal),
    );
    return _json(HttpStatus.ok, {'user': updated.toJson()});
  }

  Future<shelf.Response> _setUserPassword(
      shelf.Request request, String id) async {
    final principal = _requireSession(_admin(request));
    final body = await _readJson(request);
    final password = _requiredString(body, 'password');
    final user = await accounts.requireUserById(id);
    await accounts.setPassword(user, password, by: _by(request, principal));
    return _json(HttpStatus.ok, {'success': true});
  }
}
