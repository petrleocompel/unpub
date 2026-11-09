import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart' as shelf;

import 'authenticator.dart';

const _principalContextKey = 'unpub.principal';

const _readMethods = {'GET', 'HEAD'};

/// The read-only steps of `dart pub publish`. Checking the token here rejects
/// a bad one before the client uploads anything.
const _publishSteps = {
  'api/packages/versions/new',
  'api/packages/versions/newUploadFinish',
};

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
  final path = request.url.path;
  return path == 'healthz' || path == 'readyz';
}

/// The principal set by [authMiddleware], if the request was authenticated.
Principal? principalOf(shelf.Request request) =>
    request.context[_principalContextKey] as Principal?;

/// Authenticates requests selected by [requiresAuthentication].
///
/// Handlers read the identity with [principalOf] and stay unaware of how it
/// was established.
///
/// When [readAuthenticator] is set, every other request except the health
/// probes must pass it. Its principal is not exposed to handlers, because it
/// only grants reading and must never count as an uploader.
shelf.Middleware authMiddleware(
  Authenticator authenticator, {
  bool Function(shelf.Request) requiresAuthentication = isWriteRequest,
  Authenticator? readAuthenticator,
}) {
  return (shelf.Handler inner) {
    return (shelf.Request request) async {
      if (!requiresAuthentication(request)) {
        if (readAuthenticator == null || isHealthRequest(request)) {
          return inner(request);
        }
        try {
          await readAuthenticator.authenticate(request);
        } on AuthException catch (error) {
          return authFailureResponse(error);
        }
        return inner(request);
      }
      final Principal principal;
      try {
        principal = await authenticator.authenticate(request);
      } on AuthException catch (error) {
        return authFailureResponse(error);
      }
      return inner(request.change(context: {_principalContextKey: principal}));
    };
  };
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
        'error': {'message': error.message},
      }),
    );

String _challengeText(String message) =>
    message.replaceAll(RegExp(r'[^\x20-\x7e]'), ' ').replaceAll('"', "'");
