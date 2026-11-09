import 'dart:io';

import 'package:shelf/shelf.dart' as shelf;

import '../store/account_store.dart';
import 'accounts.dart';

/// How a request proved who it is.
enum CredentialKind {
  /// A web session started by a password login.
  session,

  /// A personal API token.
  apiToken,

  /// A deprecated token from the configuration.
  staticToken,
}

/// The identity behind an authenticated request.
class Principal {
  /// Email recorded as the uploader and checked against package uploaders.
  final String email;
  final Role role;

  /// What this credential may do, within [role].
  final Set<Scope> scopes;

  /// The name recorded in the audit trail.
  final String actor;

  /// The account behind the request. Null for a legacy static token.
  final String? userId;

  /// How this request was authenticated. A custom [Authenticator] that does
  /// not say gets [CredentialKind.apiToken], the kind with the least authority
  /// over accounts.
  final CredentialKind credentialKind;

  /// Set when the request was authenticated by a web session.
  final Session? session;

  /// Set when the request was authenticated by a token that expires.
  final DateTime? tokenExpiresAt;

  const Principal(
    this.email, {
    required this.role,
    this.scopes = allScopes,
    String? actor,
    this.userId,
    this.credentialKind = CredentialKind.apiToken,
    this.session,
    this.tokenExpiresAt,
  }) : actor = actor ?? email;

  bool get isAdmin => role == Role.admin;

  /// Whether this credential may take part in publishing at all.
  bool get canPublish => role != Role.reader && scopes.contains(Scope.publish);

  /// Whether this credential may publish to, or manage the uploaders of, a
  /// package with these [uploaders].
  ///
  /// A package without an uploaders list belongs to no one, so only an
  /// administrator can change it.
  bool canChangePackage(List<String>? uploaders) {
    if (!canPublish) return false;
    if (isAdmin) return true;
    return findEmail(uploaders, email) != null;
  }
}

/// The entry of [emails] for [email] ignoring case, because existing data can
/// differ in case from the normalized address of the account.
String? findEmail(List<String>? emails, String email) {
  final wanted = normalizeEmail(email);
  for (final candidate in emails ?? const <String>[]) {
    if (normalizeEmail(candidate) == wanted) return candidate;
  }
  return null;
}

/// An authentication failure that is reported to the client.
class AuthException implements Exception {
  final int statusCode;
  final String code;
  final String message;

  /// The request carries no valid credentials.
  const AuthException.unauthorized(this.message, {this.code = 'unauthorized'})
      : statusCode = HttpStatus.unauthorized;

  /// The credentials are valid but do not allow this request.
  const AuthException.forbidden(this.message, {this.code = 'forbidden'})
      : statusCode = HttpStatus.forbidden;

  @override
  String toString() => 'AuthException($statusCode): $message';
}

/// Resolves the [Principal] of a request.
abstract interface class Authenticator {
  /// Returns the principal of [request], or null if it presents no credential
  /// this authenticator accepts.
  Future<Principal?> authenticate(shelf.Request request);
}

/// Tries each authenticator in turn and returns the first principal.
class ChainAuthenticator implements Authenticator {
  final List<Authenticator> authenticators;

  const ChainAuthenticator(this.authenticators);

  @override
  Future<Principal?> authenticate(shelf.Request request) async {
    for (final authenticator in authenticators) {
      final principal = await authenticator.authenticate(request);
      if (principal != null) return principal;
    }
    return null;
  }
}

/// Authenticates personal API tokens sent as `Authorization: Bearer`.
class ApiTokenAuthenticator implements Authenticator {
  final AccountStore store;
  final DateTime Function() clock;

  const ApiTokenAuthenticator(this.store, {this.clock = DateTime.now});

  @override
  Future<Principal?> authenticate(shelf.Request request) async {
    final secret = bearerToken(request);
    if (secret == null) return null;
    final hash = hashSecret(secret);
    final token = await store.findTokenByHash(hash);
    final now = clock();
    if (token == null ||
        !constantTimeEquals(token.hash, hash) ||
        !token.isActiveAt(now)) {
      return null;
    }
    final user = await store.findUserById(token.userId);
    if (user == null || user.disabled) return null;
    await store.touchToken(token.id, now);
    return Principal(
      user.email,
      role: user.role,
      scopes: token.scopes,
      actor: 'token:${token.prefix}',
      userId: user.id,
      credentialKind: CredentialKind.apiToken,
      tokenExpiresAt: token.expiresAt,
    );
  }
}

/// Authenticates the session cookie of the web UI.
///
/// The CSRF token of the session is checked by the auth middleware, because
/// that may need to read the request body.
class SessionAuthenticator implements Authenticator {
  final AccountStore store;
  final DateTime Function() clock;

  const SessionAuthenticator(this.store, {this.clock = DateTime.now});

  @override
  Future<Principal?> authenticate(shelf.Request request) async {
    final cookie = sessionCookie(request);
    if (cookie == null) return null;
    final session = await store.findSession(hashSecret(cookie));
    if (session == null || !session.expiresAt.isAfter(clock())) return null;
    final user = await store.findUserById(session.userId);
    if (user == null || user.disabled) return null;
    return Principal(
      user.email,
      role: user.role,
      scopes: scopesAllowedFor(user.role),
      userId: user.id,
      credentialKind: CredentialKind.session,
      session: session,
    );
  }
}

/// Authenticates the deprecated `auth.bootstrapToken` and `auth.readTokens`.
class StaticTokenAuthenticator implements Authenticator {
  /// Acts as an administrator with [bootstrapEmail].
  final String? bootstrapToken;
  final String bootstrapEmail;

  /// Each acts as a reader.
  final Set<String> readTokens;

  const StaticTokenAuthenticator({
    this.bootstrapToken,
    this.bootstrapEmail = 'admin@localhost',
    this.readTokens = const {},
  });

  @override
  Future<Principal?> authenticate(shelf.Request request) async {
    final presented = bearerToken(request);
    if (presented == null) return null;

    final bootstrap = bootstrapToken;
    if (bootstrap != null &&
        bootstrap.isNotEmpty &&
        constantTimeEquals(presented, bootstrap)) {
      return Principal(
        bootstrapEmail,
        role: Role.admin,
        credentialKind: CredentialKind.staticToken,
      );
    }

    // Checks every token so the running time does not reveal a match.
    var matched = false;
    for (final token in readTokens) {
      matched |= constantTimeEquals(presented, token);
    }
    if (!matched) return null;
    return const Principal(
      'reader@localhost',
      role: Role.reader,
      scopes: {Scope.read},
      credentialKind: CredentialKind.staticToken,
    );
  }
}

/// The token of an `Authorization: Bearer` header, if there is one.
String? bearerToken(shelf.Request request) {
  final header = request.headers[HttpHeaders.authorizationHeader];
  if (header == null) return null;
  final parts = header.trim().split(RegExp(r'\s+'));
  if (parts.length != 2 || parts.first.toLowerCase() != 'bearer') {
    return null;
  }
  return parts.last;
}

/// The value of the session cookie of [request], if there is one.
String? sessionCookie(shelf.Request request) {
  final header = request.headers[HttpHeaders.cookieHeader];
  if (header == null) return null;
  for (final pair in header.split(';')) {
    final separator = pair.indexOf('=');
    if (separator < 0) continue;
    if (pair.substring(0, separator).trim() == sessionCookieName) {
      final value = pair.substring(separator + 1).trim();
      return value.isEmpty ? null : value;
    }
  }
  return null;
}

/// The address of the client, from `X-Forwarded-For` only when trusted.
///
/// Takes the last entry, the one added by the nearest proxy, because a client
/// can put anything in the entries before it.
String? clientAddress(shelf.Request request, {bool trustForwardedFor = false}) {
  if (trustForwardedFor) {
    final forwarded = request.headers['x-forwarded-for'];
    if (forwarded != null) {
      final last = forwarded.split(',').last.trim();
      if (last.isNotEmpty) return last;
    }
  }
  final connection = request.context['shelf.io.connection_info'];
  return connection is HttpConnectionInfo
      ? connection.remoteAddress.address
      : null;
}
