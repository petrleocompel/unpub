import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart' as shelf;

import 'logging.dart';

final _log = Logger('unpub.http');

/// Logs one line per request and turns uncaught handler errors into a 500.
shelf.Middleware requestLogger() {
  return (shelf.Handler inner) {
    return (shelf.Request request) async {
      final watch = Stopwatch()..start();

      void logRequest(int status, Level level,
          [Object? error, StackTrace? st]) {
        _log.log(
          level,
          LogEvent('request', {
            'method': request.method,
            'path': request.requestedUri.path,
            'status': status,
            'durationMs': watch.elapsedMilliseconds,
          }),
          error,
          st,
        );
      }

      try {
        final response = await inner(request);
        logRequest(response.statusCode, Level.INFO);
        return response;
      } on shelf.HijackException {
        rethrow;
      } catch (error, stackTrace) {
        logRequest(
            HttpStatus.internalServerError, Level.SEVERE, error, stackTrace);
        return shelf.Response.internalServerError(
          headers: {HttpHeaders.contentTypeHeader: ContentType.json.mimeType},
          body: json.encode({
            'error': {
              'code': 'server_error',
              'message': 'Internal Server Error'
            },
          }),
        );
      }
    };
  };
}
