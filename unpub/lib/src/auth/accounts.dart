import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Name of the cookie that carries a web session.
const sessionCookieName = 'unpub_session';

/// How long a web session lasts. Sessions are not extended by use.
const sessionLifetime = Duration(hours: 24);

const minPasswordLength = 8;
const maxPasswordLength = 1024;

/// What a user may do, whatever the credential they present.
enum Role {
  admin,
  publisher,
  reader;

  static Role? tryParse(Object? name) =>
      values.where((role) => role.name == name).firstOrNull;
}

/// What a single credential may do, within the role of its user.
enum Scope {
  read,
  publish;

  static Scope? tryParse(Object? name) =>
      values.where((scope) => scope.name == name).firstOrNull;
}

const allScopes = {Scope.read, Scope.publish};

/// The scopes a token of a user with [role] can usefully hold.
Set<Scope> scopesAllowedFor(Role role) =>
    role == Role.reader ? const {Scope.read} : allScopes;

/// The canonical form of an email address, as stored in `users`.
String normalizeEmail(String email) => email.trim().toLowerCase();

/// Whether the normalized [email] is shaped like an address.
///
/// Deliberately loose, because `admin@localhost` and addresses from existing
/// `uploaders` arrays have to pass.
bool isValidEmail(String email) {
  if (email.length > 254 || email.contains(RegExp(r'[\s\x00-\x1f\x7f]'))) {
    return false;
  }
  final at = email.indexOf('@');
  return at > 0 && at == email.lastIndexOf('@') && at < email.length - 1;
}

/// Why [password] cannot be set, or null if it can.
String? passwordProblem(String password) {
  if (password.length < minPasswordLength) {
    return 'the password must have at least $minPasswordLength characters';
  }
  if (password.length > maxPasswordLength) {
    return 'the password must have at most $maxPasswordLength characters';
  }
  return null;
}

final _random = Random.secure();

/// A random URL-safe secret of [bytes] bytes.
String generateSecret([int bytes = 32]) => base64Url
    .encode(List<int>.generate(bytes, (_) => _random.nextInt(256)))
    .replaceAll('=', '');

/// The value stored in place of a high-entropy [secret].
String hashSecret(String secret) =>
    sha256.convert(utf8.encode(secret)).toString();

/// Compares digests so the running time reveals nothing about the values.
bool constantTimeEquals(String a, String b) {
  final digestA = sha256.convert(utf8.encode(a)).bytes;
  final digestB = sha256.convert(utf8.encode(b)).bytes;
  var difference = 0;
  for (var i = 0; i < digestA.length; i++) {
    difference |= digestA[i] ^ digestB[i];
  }
  return difference == 0;
}

final _durationPattern = RegExp(r'^(\d{1,6})([smhdw])$');

/// Parses a duration such as `90s`, `12h`, `30d` or `8w`.
Duration? parseDuration(String text) {
  final match = _durationPattern.firstMatch(text.trim());
  if (match == null) return null;
  final amount = int.parse(match.group(1)!);
  if (amount == 0) return null;
  return switch (match.group(2)!) {
    's' => Duration(seconds: amount),
    'm' => Duration(minutes: amount),
    'h' => Duration(hours: amount),
    'd' => Duration(days: amount),
    _ => Duration(days: amount * 7),
  };
}

String? _isoDate(DateTime? date) => date?.toUtc().toIso8601String();

/// A local account.
class User {
  final String id;
  final String email;
  final String displayName;

  /// Null for a placeholder, who cannot log in until a password is set.
  final String? passwordHash;
  final Role role;
  final bool disabled;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? lastLoginAt;

  const User({
    required this.id,
    required this.email,
    required this.displayName,
    required this.passwordHash,
    required this.role,
    required this.disabled,
    required this.createdAt,
    required this.updatedAt,
    required this.lastLoginAt,
  });

  /// The form sent to clients. Never includes the password hash.
  Map<String, Object?> toJson() => {
        'id': id,
        'email': email,
        'displayName': displayName,
        'role': role.name,
        'disabled': disabled,
        'hasPassword': passwordHash != null,
        'createdAt': _isoDate(createdAt),
        'updatedAt': _isoDate(updatedAt),
        'lastLoginAt': _isoDate(lastLoginAt),
      };
}

/// A personal API token. Only the hash of its secret is kept.
class ApiToken {
  final String id;
  final String userId;
  final String name;

  /// The first characters of the secret, so a user can tell tokens apart.
  final String prefix;
  final String hash;
  final Set<Scope> scopes;
  final DateTime? expiresAt;
  final DateTime? lastUsedAt;
  final DateTime createdAt;
  final DateTime? revokedAt;

  const ApiToken({
    required this.id,
    required this.userId,
    required this.name,
    required this.prefix,
    required this.hash,
    required this.scopes,
    required this.expiresAt,
    required this.lastUsedAt,
    required this.createdAt,
    required this.revokedAt,
  });

  bool isActiveAt(DateTime now) =>
      revokedAt == null && (expiresAt == null || expiresAt!.isAfter(now));

  /// The form sent to clients. Never includes the hash.
  Map<String, Object?> toJson() => {
        'id': id,
        'userId': userId,
        'name': name,
        'prefix': prefix,
        'scopes': [for (final scope in scopes) scope.name],
        'expiresAt': _isoDate(expiresAt),
        'lastUsedAt': _isoDate(lastUsedAt),
        'createdAt': _isoDate(createdAt),
        'revokedAt': _isoDate(revokedAt),
      };
}

/// A server-side web session.
class Session {
  /// The hash of the cookie value, so a database read yields no live session.
  final String id;
  final String userId;
  final DateTime createdAt;
  final DateTime expiresAt;
  final String csrfToken;

  const Session({
    required this.id,
    required this.userId,
    required this.createdAt,
    required this.expiresAt,
    required this.csrfToken,
  });
}

/// A request about an account that cannot be carried out.
class AccountException implements Exception {
  final int statusCode;
  final String code;
  final String message;

  const AccountException.invalid(this.message)
      : statusCode = 400,
        code = 'invalid_request';

  const AccountException.forbidden(this.message)
      : statusCode = 403,
        code = 'forbidden';

  const AccountException.notFound(this.message)
      : statusCode = 404,
        code = 'not_found';

  const AccountException.conflict(this.message)
      : statusCode = 409,
        code = 'conflict';

  const AccountException.unavailable(this.message)
      : statusCode = 503,
        code = 'unavailable';

  @override
  String toString() => message;
}
