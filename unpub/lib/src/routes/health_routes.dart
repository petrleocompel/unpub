import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart';

import '../app.dart';
import '../redact.dart';
import 'responses.dart';

final _log = Logger('unpub.app');

/// How long a single readiness check may take.
const _healthCheckTimeout = Duration(seconds: 5);

/// `/healthz` and `/readyz`.
class HealthRoutes {
  final App app;

  HealthRoutes(this.app);

  void addRoutes(Router router) {
    router
      ..get('/healthz', healthz)
      ..get('/readyz', readyz);
  }

  Future<shelf.Response> healthz(shelf.Request req) async {
    return okWithJson({'status': 'ok'});
  }

  Future<shelf.Response> readyz(shelf.Request req) async {
    final report = await readiness();
    return shelf.Response(
      report['status'] == 'ok' ? HttpStatus.ok : HttpStatus.serviceUnavailable,
      headers: {HttpHeaders.contentTypeHeader: ContentType.json.mimeType},
      body: json.encode(report),
    );
  }

  /// What `/readyz` reports: `status`, `ok` or `unavailable`, and the
  /// `checks` of Mongo and the storage.
  Future<Map<String, Object>> readiness() async {
    final results = await Future.wait([
      _runCheck(app.metaStore.checkHealth),
      _runCheck(app.packageStore.checkHealth),
    ]);
    final ready = results.every((result) => result['status'] == 'ok');
    return {
      'status': ready ? 'ok' : 'unavailable',
      'checks': {'mongo': results[0], 'storage': results[1]},
    };
  }

  static Future<Map<String, String>> _runCheck(
      Future<void> Function() check) async {
    try {
      await check().timeout(_healthCheckTimeout);
      return {'status': 'ok'};
    } catch (err) {
      _log.warning('readiness check failed', err);
      return {'status': 'error', 'error': redactConnectionStrings('$err')};
    }
  }
}
