import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shelf/shelf.dart' as shelf;

/// The header carrying the id of a request, in the request and the response.
const requestIdHeader = 'x-request-id';

const _contextKey = 'unpub.requestId';

/// What an incoming `X-Request-Id` must look like to be kept.
final _saneRequestId = RegExp(r'^[A-Za-z0-9._-]{1,64}$');

final _random = Random.secure();

/// The id [requestIdMiddleware] gave [request], if it went through it.
String? requestIdOf(shelf.Request request) =>
    request.context[_contextKey] as String?;

/// A new request id: 32 random hex digits.
String newRequestId() => [
      for (var i = 0; i < 16; i++)
        _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();

/// Gives every request an id and sends it back in `X-Request-Id`.
///
/// The id is the incoming `X-Request-Id` when it has 1 to 64 letters, digits,
/// dots, underscores or dashes, so that a proxy in front can set it, and a
/// new one otherwise. Handlers read it with [requestIdOf]. A JSON error of a
/// 5xx response, `{"error": {...}}`, gets it as `error.requestId`, so that a
/// user can quote it and an operator find it in the log.
shelf.Middleware requestIdMiddleware() => (inner) => (request) async {
      final incoming = request.headers[requestIdHeader];
      final id = incoming != null && _saneRequestId.hasMatch(incoming)
          ? incoming
          : newRequestId();
      final response = await inner(request.change(context: {_contextKey: id}));
      final withId = response.change(headers: {requestIdHeader: id});
      if (response.statusCode < 500) return withId;
      return _withIdInError(withId, id);
    };

Future<shelf.Response> _withIdInError(
    shelf.Response response, String id) async {
  final contentType = response.headers[HttpHeaders.contentTypeHeader] ?? '';
  if (!contentType.toLowerCase().startsWith(ContentType.json.mimeType)) {
    return response;
  }
  final bytes = <int>[];
  await for (final chunk in response.read()) {
    bytes.addAll(chunk);
  }
  Object? body;
  try {
    body = json.decode(utf8.decode(bytes));
  } on FormatException {
    body = null;
  }
  if (body case {'error': final Map<String, dynamic> error}) {
    error['requestId'] = id;
    final encoded = utf8.encode(json.encode(body));
    return response.change(body: encoded, headers: {
      HttpHeaders.contentLengthHeader: '${encoded.length}',
    });
  }
  return response.change(body: bytes);
}
