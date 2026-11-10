import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart';

import '../app.dart';
import '../auth/accounts.dart';
import '../auth/auth_middleware.dart';
import '../auth/authenticator.dart';
import '../config/config.dart';
import '../metrics.dart';
import 'responses.dart';

final _log = Logger('unpub.metrics');

/// How long the package counts are reused between scrapes.
const _countsMaxAge = Duration(seconds: 30);

/// How long the storage size is reused, as measuring it lists everything.
const storageSizeMaxAge = Duration(minutes: 10);

const _probeTimeout = Duration(seconds: 5);

/// What `/metrics` reads from the stores, each value cached.
class MetricsSources {
  final App app;

  MetricsSources(this.app);

  late final _counts = CachedValue(app.metaStore.counts, maxAge: _countsMaxAge);

  late final _storage =
      CachedValue(app.packageStore.totalSize, maxAge: storageSizeMaxAge);

  /// The gauges now. A store that fails leaves its gauges out, and Mongo
  /// down.
  Future<MetricsSnapshot> snapshot() async {
    final mongoUp = await _probe(() async {
          await app.metaStore.checkHealth();
          return true;
        }) ??
        false;
    final counts = mongoUp ? await _probe(_counts.get) : null;
    final storage = await _probe(_storage.get);
    return MetricsSnapshot(
      packages: counts?.packages,
      versions: counts?.versions,
      storageBytes: storage,
      mongoUp: mongoUp,
    );
  }

  /// The value of [read], or null if it failed.
  static Future<T?> _probe<T>(Future<T> Function() read) async {
    try {
      return await read().timeout(_probeTimeout);
    } catch (error) {
      _log.fine('metrics source failed: $error');
      return null;
    }
  }
}

/// `/metrics`, in the Prometheus text format.
class MetricsRoutes {
  final App app;

  MetricsRoutes(this.app);

  void addRoutes(Router router) {
    router.get('/metrics', metrics);
  }

  MetricsConfig get _config => app.config?.metrics ?? const MetricsConfig();

  /// `metrics.token` always opens it, and so does an administrator with the
  /// read scope. Without a token configured, anyone may read it while reads
  /// are public.
  shelf.Response? _refusal(shelf.Request req) {
    final token = _config.token;
    final presented = bearerToken(req);
    if (token != null &&
        presented != null &&
        constantTimeEquals(presented, token)) {
      return null;
    }
    final principal = principalOf(req);
    if (principal != null &&
        principal.isAdmin &&
        principal.scopes.contains(Scope.read)) {
      return null;
    }
    if (token == null && app.readAccess == ReadAccess.public) return null;
    if (principal != null) {
      return forbidden('reading the metrics needs metrics.token or an '
          'administrator');
    }
    return shelf.Response(HttpStatus.unauthorized,
        body: 'metrics.token or an administrator token is required\n',
        headers: {
          HttpHeaders.contentTypeHeader: 'text/plain; charset=utf-8',
          HttpHeaders.wwwAuthenticateHeader: 'Bearer realm="metrics"',
        });
  }

  Future<shelf.Response> metrics(shelf.Request req) async {
    if (!_config.enabled) return notFound();
    final refusal = _refusal(req);
    if (refusal != null) return refusal;
    final body = app.metrics.render(await app.metricsSources.snapshot());
    return shelf.Response.ok(body, headers: {
      HttpHeaders.contentTypeHeader: 'text/plain; version=0.0.4; charset=utf-8',
      HttpHeaders.cacheControlHeader: 'no-store',
    });
  }
}
