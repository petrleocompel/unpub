import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shelf/shelf.dart' as shelf;

import '../auth/auth_middleware.dart';
import '../auth/authenticator.dart';
import '../package_moderation.dart';
import '../upstream/upstream_proxy.dart';
import '../validation.dart';

export '../paging.dart';

/// Largest JSON body read by the package management routes.
const _maxJsonBodyBytes = 64 * 1024;

shelf.Response okWithJson(Map<String, dynamic> data,
        {Map<String, String> headers = const {}, int status = HttpStatus.ok}) =>
    shelf.Response(
      status,
      body: json.encode(data),
      headers: {
        HttpHeaders.contentTypeHeader: ContentType.json.mimeType,
        'Access-Control-Allow-Origin': '*',
        ...headers,
      },
    );

shelf.Response successMessage(String message) => okWithJson({
      'success': {'message': message}
    });

/// The error code of a response with [status], when nothing more specific
/// applies.
String errorCodeFor(int status) => switch (status) {
      HttpStatus.badRequest => 'invalid_request',
      HttpStatus.unauthorized => 'unauthorized',
      HttpStatus.forbidden => 'forbidden',
      HttpStatus.notFound => 'not_found',
      HttpStatus.conflict => 'conflict',
      HttpStatus.requestEntityTooLarge => 'too_large',
      HttpStatus.tooManyRequests => 'rate_limited',
      HttpStatus.badGateway => 'bad_gateway',
      HttpStatus.serviceUnavailable => 'unavailable',
      _ => status >= 500 ? 'server_error' : 'invalid_request',
    };

/// The error `{"error": {"code": ..., "message": ...}}`, with [code]
/// derived from [status] unless given.
shelf.Response badRequest(String message,
        {int status = HttpStatus.badRequest, String? code}) =>
    shelf.Response(
      status,
      headers: {HttpHeaders.contentTypeHeader: ContentType.json.mimeType},
      body: json.encode({
        'error': {'code': code ?? errorCodeFor(status), 'message': message}
      }),
    );

shelf.Response forbidden(String message) =>
    badRequest(message, status: HttpStatus.forbidden);

shelf.Response conflict(String message) =>
    badRequest(message, status: HttpStatus.conflict);

shelf.Response notFound([String message = 'Not Found']) =>
    badRequest(message, status: HttpStatus.notFound);

shelf.Response badGateway(UpstreamException error) =>
    badRequest(error.message, status: HttpStatus.badGateway);

/// The response for a request that reached a route unauthenticated, which
/// happens only if the router is mounted without [authMiddleware].
shelf.Response unauthenticated() => authFailureResponse(
    const AuthException.unauthorized('Authentication is required.'));

/// The version named by a path [segment], or null if it is not one.
///
/// The router passes segments still percent encoded, such as `+` as `%2B`.
/// Decoding cannot fail, because shelf rejects such requests before routing.
String? parseVersionSegment(String segment) {
  final version = Uri.decodeComponent(segment);
  return isValidPackageVersion(version) ? version : null;
}

/// The JSON value of the request body, or null if it is too large or not
/// valid JSON.
Future<Object?> readJsonBody(shelf.Request req) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in req.read()) {
    bytes.add(chunk);
    if (bytes.length > _maxJsonBodyBytes) return null;
  }
  try {
    return json.decode(utf8.decode(bytes.takeBytes()));
  } on FormatException {
    return null;
  }
}

/// The success message of [change], or the error refusing it.
Future<shelf.Response> moderationResponse(
    Future<String> Function() change) async {
  try {
    return successMessage(await change());
  } on ModerationException catch (error) {
    return badRequest(error.message, status: error.statusCode);
  }
}
