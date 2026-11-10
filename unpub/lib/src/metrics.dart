// PatternRouter extends the sealed Router, see there.
// ignore_for_file: subtype_of_sealed_class

import 'dart:async';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart';

import 'auth/account_api.dart' show AccountApi;
import 'version.dart';

/// The upper bounds, in seconds, of the request duration histogram.
const durationBuckets = [0.005, 0.025, 0.1, 0.5, 2.5, 10.0];

/// The route label of a request that no route matched.
const unmatchedRoute = 'unmatched';

/// A [Router] that remembers the pattern of every route, so that metrics can
/// label a request by its route rather than its path, which keeps the number
/// of series bounded.
///
/// It only overrides the public [add], which every route module goes through,
/// so extending the sealed class is safe. Composing instead would change the
/// `addRoutes(Router)` of every module, [AccountApi] included.
class PatternRouter extends Router {
  final _patterns = <(String, String, RegExp)>[];

  PatternRouter({super.notFoundHandler});

  @override
  void add(String verb, String route, Function handler) {
    final upper = verb.toUpperCase();
    _patterns.add((upper, route, _compile(route)));
    if (upper == 'GET') _patterns.add(('HEAD', route, _compile(route)));
    super.add(verb, route, handler);
  }

  /// `<name>` matches a segment, `<name|regexp>` what the regexp matches, as
  /// in shelf_router.
  static RegExp _compile(String route) {
    final pattern = StringBuffer('^');
    var index = 0;
    for (final match in RegExp(r'<([^>|]+)(?:\|([^>]*))?>').allMatches(route)) {
      pattern
        ..write(RegExp.escape(route.substring(index, match.start)))
        ..write('(${match[2] ?? '[^/]+'})');
      index = match.end;
    }
    pattern
      ..write(RegExp.escape(route.substring(index)))
      ..write(r'$');
    return RegExp(pattern.toString());
  }

  /// The pattern of the first route [method] and [path] match, as the router
  /// would choose it.
  String? patternOf(String method, String path) {
    final upper = method.toUpperCase();
    for (final (verb, route, regexp) in _patterns) {
      if (verb == upper && regexp.hasMatch(path)) return route;
    }
    return null;
  }
}

/// A Prometheus label value, escaped.
String _label(String value) => value
    .replaceAll(r'\', r'\\')
    .replaceAll('"', r'\"')
    .replaceAll('\n', r'\n');

String _number(num value) {
  if (value is int) return '$value';
  if (value.isNaN) return 'NaN';
  if (value.isInfinite) return value > 0 ? '+Inf' : '-Inf';
  return value.toString();
}

class _Histogram {
  final counts = List.filled(durationBuckets.length, 0);
  var count = 0;
  var sum = 0.0;

  void observe(double seconds) {
    for (var i = 0; i < durationBuckets.length; i++) {
      if (seconds <= durationBuckets[i]) counts[i]++;
    }
    count++;
    sum += seconds;
  }
}

/// Gauges read from the stores when `/metrics` is scraped.
class MetricsSnapshot {
  final int? packages;
  final int? versions;
  final int? storageBytes;
  final bool mongoUp;

  const MetricsSnapshot({
    this.packages,
    this.versions,
    this.storageBytes,
    required this.mongoUp,
  });
}

/// The counters of this process, written in the Prometheus text format
/// 0.0.4. Counters start at zero with the process, as Prometheus expects.
class Metrics {
  final DateTime startedAt;

  final _requests = <(String, String, int), int>{};
  final _durations = <String, _Histogram>{};
  var downloads = 0;
  var publishes = 0;
  final _upstreamFetches = <String, int>{};
  final _webhookDeliveries = <String, int>{};

  Metrics({DateTime? startedAt}) : startedAt = startedAt ?? DateTime.now();

  void countRequest(String route, String method, int status, Duration took) {
    final key = (route, method, status);
    _requests[key] = (_requests[key] ?? 0) + 1;
    _durations
        .putIfAbsent(route, _Histogram.new)
        .observe(took.inMicroseconds / Duration.microsecondsPerSecond);
  }

  void countUpstreamFetch(String result) =>
      _upstreamFetches[result] = (_upstreamFetches[result] ?? 0) + 1;

  void countWebhookDelivery(String result) =>
      _webhookDeliveries[result] = (_webhookDeliveries[result] ?? 0) + 1;

  /// Counts every request [router] answers, by the pattern of its route.
  shelf.Middleware middleware(PatternRouter router) =>
      (inner) => (request) async {
            final watch = Stopwatch()..start();
            final route =
                router.patternOf(request.method, '/${request.url.path}') ??
                    unmatchedRoute;
            try {
              final response = await inner(request);
              countRequest(
                  route, request.method, response.statusCode, watch.elapsed);
              return response;
            } on shelf.HijackException {
              rethrow;
            } catch (_) {
              countRequest(route, request.method, 500, watch.elapsed);
              rethrow;
            }
          };

  /// The exposition of every metric, with the gauges of [snapshot].
  String render(MetricsSnapshot snapshot) {
    final out = StringBuffer();
    void family(String name, String type, String help) => out
      ..writeln('# HELP $name $help')
      ..writeln('# TYPE $name $type');
    void sample(String name, num value,
        [Map<String, String> labels = const {}]) {
      out.write(name);
      if (labels.isNotEmpty) {
        out.write('{');
        out.write([
          for (final MapEntry(:key, :value) in labels.entries)
            '$key="${_label(value)}"',
        ].join(','));
        out.write('}');
      }
      out.writeln(' ${_number(value)}');
    }

    family('unpub_build_info', 'gauge', 'The version of this server.');
    sample('unpub_build_info', 1, {'version': packageVersion});

    family('process_start_time_seconds', 'gauge',
        'When this process started, in seconds since the epoch.');
    sample(
        'process_start_time_seconds', startedAt.millisecondsSinceEpoch ~/ 1000);

    family('unpub_http_requests_total', 'counter',
        'HTTP requests answered, by route pattern, method and status.');
    final requests = _requests.entries.toList()
      ..sort((a, b) => '${a.key}'.compareTo('${b.key}'));
    for (final MapEntry(key: (route, method, status), :value) in requests) {
      sample('unpub_http_requests_total', value,
          {'route': route, 'method': method, 'status': '$status'});
    }

    family('unpub_http_request_duration_seconds', 'histogram',
        'How long answering took, by route pattern.');
    final routes = _durations.keys.toList()..sort();
    for (final route in routes) {
      final histogram = _durations[route]!;
      for (var i = 0; i < durationBuckets.length; i++) {
        sample(
            'unpub_http_request_duration_seconds_bucket', histogram.counts[i], {
          'route': route,
          'le': _number(durationBuckets[i]),
        });
      }
      sample('unpub_http_request_duration_seconds_bucket', histogram.count,
          {'route': route, 'le': '+Inf'});
      sample('unpub_http_request_duration_seconds_sum', histogram.sum,
          {'route': route});
      sample('unpub_http_request_duration_seconds_count', histogram.count,
          {'route': route});
    }

    family('unpub_downloads_total', 'counter',
        'Archive downloads by the pub client counted by this process.');
    sample('unpub_downloads_total', downloads);

    family('unpub_publishes_total', 'counter',
        'Versions published through this process.');
    sample('unpub_publishes_total', publishes);

    family('unpub_upstream_fetches_total', 'counter',
        'Requests to the upstream registry in proxy mode, by result.');
    for (final result in _sorted(_upstreamFetches)) {
      sample('unpub_upstream_fetches_total', _upstreamFetches[result]!,
          {'result': result});
    }

    family('unpub_webhook_deliveries_total', 'counter',
        'Webhook delivery attempts made by this process, by result.');
    for (final result in _sorted(_webhookDeliveries)) {
      sample('unpub_webhook_deliveries_total', _webhookDeliveries[result]!,
          {'result': result});
    }

    if (snapshot.packages case final packages?) {
      family('unpub_packages', 'gauge', 'Packages published here.');
      sample('unpub_packages', packages);
    }
    if (snapshot.versions case final versions?) {
      family('unpub_versions', 'gauge', 'Versions published here.');
      sample('unpub_versions', versions);
    }
    if (snapshot.storageBytes case final bytes?) {
      family(
          'unpub_storage_bytes',
          'gauge',
          'Bytes held by the package store, measured at most every 10 '
              'minutes.');
      sample('unpub_storage_bytes', bytes);
    }
    family('unpub_mongo_up', 'gauge', 'Whether MongoDB answered a ping.');
    sample('unpub_mongo_up', snapshot.mongoUp ? 1 : 0);
    return out.toString();
  }

  static List<String> _sorted(Map<String, int> counts) =>
      counts.keys.toList()..sort();
}

/// A value that is computed again only once it is older than [maxAge].
class CachedValue<T> {
  final Duration maxAge;
  final Future<T> Function() compute;
  final DateTime Function() clock;
  T? _value;
  DateTime? _at;
  Future<T>? _running;

  CachedValue(this.compute, {required this.maxAge, this.clock = DateTime.now});

  Future<T> get() async {
    final at = _at;
    if (at != null && clock().difference(at) < maxAge) return _value as T;
    final running = _running ??= compute();
    try {
      final value = await running;
      _value = value;
      _at = clock();
      return value;
    } finally {
      _running = null;
    }
  }
}
