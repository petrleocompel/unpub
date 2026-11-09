import 'dart:convert';
import 'dart:io';

import 'package:http_parser/http_parser.dart';
import 'package:shelf/shelf.dart' as shelf;

import '../config/config.dart';
import 'accounts.dart';
import 'authenticator.dart';

const _principalContextKey = 'unpub.principal';

const _readMethods = {'GET', 'HEAD'};
const _safeMethods = {..._readMethods, 'OPTIONS'};

/// The read-only steps of `dart pub publish`. Checking the token here rejects
/// a bad one before the client uploads anything.
const _publishSteps = {
  'api/packages/versions/new',
  'api/packages/versions/newUploadFinish',
};

/// Field of a form post that can carry the CSRF token instead of the header.
const csrfFormField = 'csrf_token';
const csrfHeader = 'x-csrf-token';

/// Largest form body read while looking for the CSRF token.
const _maxFormBytes = 1 << 20;

/// Whether [request] must carry the credentials to change the registry.
///
/// Denies by default: every method other than GET, HEAD and OPTIONS is a
/// write, so a new route cannot be left unprotected by omission.
bool isWriteRequest(shelf.Request request) {
  if (request.method == 'OPTIONS') return false;
  return !_readMethods.contains(request.method) ||
      _publishSteps.contains(request.url.path);
}

/// Whether [request] targets a probe that stays open in every read mode.
bool isHealthRequest(shelf.Request request) {
  final path = request.url.path.replaceFirst(RegExp(r'/+$'), '');
  return path == 'healthz' || path == 'readyz';
}

bool _isLoginRequest(shelf.Request request) =>
    request.method == 'POST' && request.url.path == 'webapi/login';

/// Whether [path] is where a signed-in user looks after their own account.
///
/// These are writes, but they change nothing in the registry, and a reader
/// has to be able to log out, change a password and get a token to read with.
bool _isOwnAccountRoute(String path) =>
    path == 'webapi/logout' ||
    path == 'webapi/me/password' ||
    path == 'webapi/tokens' ||
    path.startsWith('webapi/tokens/');

/// The principal set by [authMiddleware], if the request was authenticated.
Principal? principalOf(shelf.Request request) =>
    request.context[_principalContextKey] as Principal?;

/// Establishes who is making each request and enforces the coarse rules.
///
/// Anything with credentials that are missing or not accepted is anonymous,
/// and may only use safe methods while [readAccess] is `public`, plus the
/// health probes and the login endpoint. Handlers read the identity with
/// [principalOf] and apply the rules specific to their resource.
shelf.Middleware authMiddleware(
  Authenticator authenticator, {
  ReadAccess readAccess = ReadAccess.public,
}) {
  return (shelf.Handler inner) {
    return (shelf.Request request) async {
      // Login is exempt from authentication so that a stale cookie, which
      // would otherwise demand a CSRF token, cannot prevent logging back in.
      if (isHealthRequest(request) || _isLoginRequest(request)) {
        return inner(request);
      }

      try {
        final principal = await authenticator.authenticate(request);
        _authorize(request, principal, readAccess);
        var authorized = request;
        final session = principal?.session;
        if (session != null && !_safeMethods.contains(request.method)) {
          authorized = await _checkCsrf(request, session.csrfToken);
        }
        return inner(principal == null
            ? authorized
            : authorized.change(context: {_principalContextKey: principal}));
      } on AuthException catch (error) {
        return authFailureResponse(error);
      }
    };
  };
}

void _authorize(
    shelf.Request request, Principal? principal, ReadAccess readAccess) {
  if (isWriteRequest(request)) {
    if (principal == null) {
      throw AuthException.unauthorized(_hasAuthorization(request)
          ? 'Invalid Bearer token.'
          : 'Missing Bearer token. '
              'Add one with: dart pub token add <server url>');
    }
    if (principal.credentialKind == CredentialKind.session &&
        _isOwnAccountRoute(request.url.path)) {
      return;
    }
    if (!principal.scopes.contains(Scope.publish)) {
      throw const AuthException.forbidden('This credential is read-only.',
          code: 'insufficient_scope');
    }
    if (!principal.canPublish) {
      throw const AuthException.forbidden(
          'This account is not allowed to publish packages.');
    }
    return;
  }
  if (readAccess == ReadAccess.public) return;
  if (principal == null) {
    throw AuthException.unauthorized(_hasAuthorization(request)
        ? 'Invalid Bearer token.'
        : 'This server requires a Bearer token to read packages. '
            'Add one with: dart pub token add <server url>');
  }
  if (!principal.scopes.contains(Scope.read)) {
    throw const AuthException.forbidden('This token cannot read packages.',
        code: 'insufficient_scope');
  }
}

bool _hasAuthorization(shelf.Request request) =>
    request.headers.containsKey(HttpHeaders.authorizationHeader);

/// Returns a request that can still be read after checking its CSRF token.
Future<shelf.Request> _checkCsrf(shelf.Request request, String expected) async {
  const failure = AuthException.forbidden('Missing or invalid CSRF token.',
      code: 'csrf_failed');

  final header = request.headers[csrfHeader];
  if (header != null) {
    if (!constantTimeEquals(header, expected)) throw failure;
    return request;
  }

  final contentType = request.headers[HttpHeaders.contentTypeHeader];
  if (contentType == null) throw failure;
  final MediaType mediaType;
  try {
    mediaType = MediaType.parse(contentType);
  } on FormatException {
    throw failure;
  }
  if (mediaType.mimeType != 'application/x-www-form-urlencoded') throw failure;

  final bytes = <int>[];
  await for (final chunk in request.read()) {
    bytes.addAll(chunk);
    if (bytes.length > _maxFormBytes) throw failure;
  }
  final Map<String, String> fields;
  try {
    fields = Uri.splitQueryString(utf8.decode(bytes));
  } on FormatException {
    throw failure;
  }
  final field = fields[csrfFormField];
  if (field == null || !constantTimeEquals(field, expected)) throw failure;
  return request.change(body: bytes);
}

/// The JSON response, with a challenge, reporting [error] to the client.
shelf.Response authFailureResponse(AuthException error) => shelf.Response(
      error.statusCode,
      headers: {
        HttpHeaders.contentTypeHeader: ContentType.json.mimeType,
        // `dart pub` prints the message of a challenge with realm "pub".
        HttpHeaders.wwwAuthenticateHeader:
            'Bearer realm="pub", message="${_challengeText(error.message)}"',
      },
      body: json.encode({
        'error': {'code': error.code, 'message': error.message},
      }),
    );

String _challengeText(String message) =>
    message.replaceAll(RegExp(r'[^\x20-\x7e]'), ' ').replaceAll('"', "'");
