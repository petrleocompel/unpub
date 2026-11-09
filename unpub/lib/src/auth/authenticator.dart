import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart' as shelf;

/// The identity behind an authenticated request.
class Principal {
  /// Email recorded as the uploader and checked against package uploaders.
  final String email;

  const Principal(this.email);
}

/// An authentication failure that is reported to the client.
class AuthException implements Exception {
  final int statusCode;
  final String message;

  /// The request carries no valid credentials.
  const AuthException.unauthorized(this.message)
      : statusCode = HttpStatus.unauthorized;

  /// The request cannot be authorized, whatever its credentials.
  const AuthException.forbidden(this.message)
      : statusCode = HttpStatus.forbidden;

  @override
  String toString() => 'AuthException($statusCode): $message';
}

/// Resolves the [Principal] of a request.
abstract interface class Authenticator {
  /// Returns the principal of [request], or throws an [AuthException].
  Future<Principal> authenticate(shelf.Request request);
}

/// Authenticates a single shared Bearer token from `auth.bootstrapToken`.
class BootstrapTokenAuthenticator implements Authenticator {
  final String? token;
  final String email;

  const BootstrapTokenAuthenticator({
    required this.token,
    this.email = 'admin@localhost',
  });

  @override
  Future<Principal> authenticate(shelf.Request request) async {
    final expected = token;
    if (expected == null || expected.isEmpty) {
      throw const AuthException.forbidden(
          'Publishing is disabled on this server. Set auth.bootstrapToken in '
          'unpub.yaml or the UNPUB_AUTH_BOOTSTRAP_TOKEN environment variable.');
    }

    final presented = _bearerToken(request);
    if (presented == null) {
      throw const AuthException.unauthorized(
          'Missing Bearer token. Add one with: dart pub token add <server url>');
    }
    if (!_constantTimeEquals(presented, expected)) {
      throw const AuthException.unauthorized('Invalid Bearer token.');
    }
    return Principal(email);
  }

  static String? _bearerToken(shelf.Request request) {
    final header = request.headers[HttpHeaders.authorizationHeader];
    if (header == null) return null;
    final parts = header.trim().split(RegExp(r'\s+'));
    if (parts.length != 2 || parts.first.toLowerCase() != 'bearer') {
      return null;
    }
    return parts.last;
  }

  /// Compares digests so the running time reveals nothing about the token.
  static bool _constantTimeEquals(String a, String b) {
    final digestA = sha256.convert(utf8.encode(a)).bytes;
    final digestB = sha256.convert(utf8.encode(b)).bytes;
    var difference = 0;
    for (var i = 0; i < digestA.length; i++) {
      difference |= digestA[i] ^ digestB[i];
    }
    return difference == 0;
  }
}
