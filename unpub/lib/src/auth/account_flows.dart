import 'account_service.dart';
import 'accounts.dart';
import 'authenticator.dart';
import 'rate_limiter.dart';

/// The steps of the account endpoints that the JSON API and the web pages
/// share, so that both enforce the same rules.

/// The `Set-Cookie` value that starts a session with the cookie [value].
String sessionCookieHeader(String value, {required bool secure}) =>
    '$sessionCookieName=$value; '
    'Path=/; HttpOnly; SameSite=Lax; Max-Age=${sessionLifetime.inSeconds}'
    '${secure ? '; Secure' : ''}';

/// The `Set-Cookie` value that ends the session in the browser.
String clearedSessionCookieHeader({required bool secure}) =>
    '$sessionCookieName=; '
    'Path=/; HttpOnly; SameSite=Lax; Max-Age=0'
    '${secure ? '; Secure' : ''}';

/// Rejects everything except a password login.
///
/// Changing credentials or roles would let a narrowed or expiring token
/// trade itself for full access, so no token may do it. The command line
/// goes through [AccountService] directly and is not affected.
Principal requirePasswordSession(Principal principal) {
  if (principal.credentialKind != CredentialKind.session) {
    throw const AuthException.forbidden(
        'Log in with a password to do this. API tokens cannot change '
        'credentials or roles.',
        code: 'session_required');
  }
  return principal;
}

/// Rejects a token that was not granted [Scope.read].
void requireReadScope(Principal principal) {
  if (!principal.scopes.contains(Scope.read)) {
    throw const AuthException.forbidden('This token cannot read.',
        code: 'insufficient_scope');
  }
}

/// The scopes a new token of [user] gets for the requested [raw] scope
/// names, all that [principal] holds and the role allows when null.
///
/// A token cannot create a token that can do more than itself.
Set<Scope> requestedScopes(Object? raw, Principal principal, User user) {
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

/// The expiry of a new token living for [expiresIn], such as `30d`, or for
/// ever when null. A token cannot outlive the one creating it.
DateTime? requestedExpiry(
    String? expiresIn, Principal principal, DateTime now) {
  DateTime? expiresAt;
  if (expiresIn != null) {
    final duration = parseDuration(expiresIn);
    if (duration == null) {
      throw const AccountException.invalid(
          'expiresIn must look like 12h, 30d or 8w');
    }
    expiresAt = now.add(duration);
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

/// How a login or a password check went.
sealed class CredentialCheck {
  const CredentialCheck();
}

/// Too many failures, try again after [wait].
final class Throttled extends CredentialCheck {
  final Duration wait;

  const Throttled(this.wait);
}

/// The password was not accepted.
final class Rejected extends CredentialCheck {
  const Rejected();
}

/// The login succeeded and started [result].
final class LoggedIn extends CredentialCheck {
  final LoginResult result;

  const LoggedIn(this.result);
}

/// The password was changed.
final class PasswordChanged extends CredentialCheck {
  const PasswordChanged();
}

/// Logs in with [email], already normalized and valid, counting failures
/// from [address] in [limiter]. A successful login ends [previousCookie], the
/// session the browser held before.
Future<CredentialCheck> attemptLogin(
  AccountService accounts,
  LoginRateLimiter limiter, {
  required String email,
  required String password,
  required String? address,
  String? previousCookie,
}) async {
  final wait = limiter.acquire(address, email);
  if (wait != null) return Throttled(wait);

  final result =
      await accounts.login(email: email, password: password, ip: address);
  if (result == null) return const Rejected();
  limiter.succeeded(address, email);

  // A new login replaces whatever session this browser held before.
  if (previousCookie != null) await accounts.logout(previousCookie);
  return LoggedIn(result);
}

/// Replaces the password of [user] after checking [current], counting
/// failures like logins. The session [keepSessionId] stays valid.
Future<CredentialCheck> changeOwnPassword(
  AccountService accounts,
  LoginRateLimiter limiter, {
  required User user,
  required String current,
  required String replacement,
  required String? address,
  required AuditContext by,
  String? keepSessionId,
}) async {
  final wait = limiter.acquire(address, user.email);
  if (wait != null) return Throttled(wait);
  if (!await accounts.verifyPassword(user, current)) return const Rejected();
  limiter.succeeded(address, user.email);

  await accounts.setPassword(user, replacement,
      by: by, keepSessionId: keepSessionId);
  return const PasswordChanged();
}
