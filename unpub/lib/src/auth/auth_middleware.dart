import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart' as shelf;

import 'authenticator.dart';

const _principalContextKey = 'unpub.principal';

final _publishPath = RegExp(r'^api/packages/versions/new(Upload(Finish)?)?$');
final _uploadersPath = RegExp(r'^api/packages/[^/]+/uploaders(/[^/]+)?$');

/// Whether [request] targets publishing or uploader management.
bool isWriteRequest(shelf.Request request) {
  if (request.method == 'OPTIONS') return false;
  final path = request.url.path;
  return _publishPath.hasMatch(path) || _uploadersPath.hasMatch(path);
}

/// The principal set by [authMiddleware], if the request was authenticated.
Principal? principalOf(shelf.Request request) =>
    request.context[_principalContextKey] as Principal?;

/// Authenticates requests selected by [requiresAuthentication].
///
/// Handlers read the identity with [principalOf] and stay unaware of how it
/// was established.
shelf.Middleware authMiddleware(
  Authenticator authenticator, {
  bool Function(shelf.Request) requiresAuthentication = isWriteRequest,
}) {
  return (shelf.Handler inner) {
    return (shelf.Request request) async {
      if (!requiresAuthentication(request)) return inner(request);
      final Principal principal;
      try {
        principal = await authenticator.authenticate(request);
      } on AuthException catch (error) {
        return _denied(error);
      }
      return inner(request.change(context: {_principalContextKey: principal}));
    };
  };
}

shelf.Response _denied(AuthException error) => shelf.Response(
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
