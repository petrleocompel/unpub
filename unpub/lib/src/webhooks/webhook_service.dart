import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:mongo_dart/mongo_dart.dart' show ObjectId;

import '../auth/account_service.dart';
import '../auth/accounts.dart' show generateSecret;
import '../config/config.dart';
import '../logging.dart';
import '../store/audit_store.dart';
import '../version.dart';
import 'address_policy.dart';
import 'webhook_store.dart';

final _log = Logger('unpub.webhooks');

/// The most of an answer kept with a delivery.
const maxResponseSnippet = 1024;

const _maxDescriptionLength = 200;

/// The delays before the second, third and later attempts. The last one
/// repeats.
const defaultRetryDelays = [
  Duration(seconds: 30),
  Duration(minutes: 2),
  Duration(minutes: 10),
  Duration(hours: 1),
];

/// A refused change of a webhook, with the HTTP status to report.
class WebhookException implements Exception {
  final int statusCode;
  final String message;

  const WebhookException(this.statusCode, this.message);

  const WebhookException.invalid(this.message)
      : statusCode = HttpStatus.badRequest;

  const WebhookException.notFound([this.message = 'no such webhook'])
      : statusCode = HttpStatus.notFound;

  @override
  String toString() => message;
}

/// What happened, for the webhooks that subscribe to [event].
class WebhookEvent {
  final String event;
  final String package;
  final String? version;

  /// The email of whoever caused it.
  final String actor;
  final Map<String, Object?> data;

  const WebhookEvent(this.event,
      {required this.package,
      this.version,
      required this.actor,
      this.data = const {}});
}

/// How one delivery attempt ended, as counted by `/metrics`.
enum DeliveryResult {
  /// A 2xx answer.
  success,

  /// Anything else, to be tried again.
  retry,

  /// The last attempt failed too.
  failed,

  /// The URL or its address is not allowed, so trying again cannot help.
  refused,
}

/// The webhooks of the registry: managing them, queueing events for them and
/// delivering those from the `webhook_deliveries` queue.
///
/// The queue is shared by every instance. An instance claims one delivery at
/// a time, for longer than an attempt can take, so that two instances never
/// send the same attempt.
class WebhookService {
  final WebhookStore store;
  final WebhooksConfig config;
  final AuditStore audit;

  /// The delays between attempts, [defaultRetryDelays] unless a test needs
  /// shorter ones. A tenth of jitter either way is added.
  final List<Duration> retryDelays;

  /// How often the worker looks for due deliveries when nothing kicks it.
  final Duration pollInterval;

  /// How many deliveries one instance sends at the same time.
  final int concurrency;

  /// Called after each attempt, for the metrics.
  void Function(DeliveryResult result)? onAttempt;

  /// Resolves host names, [InternetAddress.lookup] unless a test replaces it.
  final Future<List<InternetAddress>> Function(String host)? lookup;

  final String _owner = ObjectId().oid;
  final _random = Random();
  Timer? _timer;
  bool _stopped = true;
  int _lanes = 0;
  bool _again = false;
  final _idle = <Completer<void>>[];

  WebhookService(
    this.store, {
    this.config = const WebhooksConfig(),
    this.audit = const NullAuditStore(),
    this.retryDelays = defaultRetryDelays,
    this.pollInterval = const Duration(seconds: 5),
    this.concurrency = 4,
    this.onAttempt,
    this.lookup,
  });

  /// How long a claim lasts: an attempt plus room to record its outcome.
  Duration get _lease => config.timeout + const Duration(seconds: 30);

  // Management.

  static List<String> _checkedEvents(Object? events) {
    if (events is! List || events.isEmpty) {
      throw const WebhookException.invalid(
          'events must list at least one event');
    }
    final unknown = events.where((event) => !webhookEvents.contains(event));
    if (unknown.isNotEmpty) {
      throw WebhookException.invalid('unknown events: ${unknown.join(', ')}. '
          'Known events: ${webhookEvents.join(', ')}');
    }
    return {for (final event in events) event as String}.toList();
  }

  Uri _checkedUrl(Object? url) {
    final parsed = url is String ? Uri.tryParse(url.trim()) : null;
    final problem = webhookUrlProblem(parsed, allowHttp: config.allowHttp);
    if (problem != null) throw WebhookException.invalid(problem);
    return parsed!;
  }

  static String _checkedDescription(Object? description) {
    if (description == null) return '';
    if (description is! String) {
      throw const WebhookException.invalid('description must be a string');
    }
    final trimmed = description.trim();
    if (trimmed.length > _maxDescriptionLength) {
      throw const WebhookException.invalid(
          'description must have at most $_maxDescriptionLength characters');
    }
    return trimmed;
  }

  Future<Webhook> require(String id) async {
    final hook = await store.find(id);
    if (hook == null) throw const WebhookException.notFound();
    return hook;
  }

  /// Creates a webhook, and returns it with its secret, which is only
  /// available now.
  Future<(Webhook, String)> create({
    required Object? url,
    required Object? events,
    Object? description,
    required AuditContext by,
  }) async {
    final checkedUrl = _checkedUrl(url);
    final checkedEvents = _checkedEvents(events);
    final checkedDescription = _checkedDescription(description);
    final secret = generateSecret();
    final hook = await store.insert(
      url: checkedUrl,
      events: checkedEvents,
      description: checkedDescription,
      secret: secret,
      createdBy: by.actor,
    );
    await audit.recordSafely(by.event('webhook.created',
        target: 'webhook:${hook.id}',
        details: {'url': '${hook.url}', 'events': hook.events}));
    return (hook, secret);
  }

  /// Changes the fields that are given.
  Future<Webhook> update(
    String id, {
    Object? url,
    Object? events,
    Object? description,
    Object? enabled,
    required AuditContext by,
  }) async {
    if (enabled != null && enabled is! bool) {
      throw const WebhookException.invalid('enabled must be true or false');
    }
    final current = await require(id);
    final fields = <String, Object>{
      if (url != null) 'url': '${_checkedUrl(url)}',
      if (events != null) 'events': _checkedEvents(events),
      if (description != null) 'description': _checkedDescription(description),
      if (enabled != null) 'enabled': enabled,
    };
    final changed = {
      for (final MapEntry(:key, :value) in fields.entries)
        if (value.toString() != current.toJson()[key].toString()) key: value,
    };
    if (changed.isEmpty) return current;
    if (!await store.update(id, changed)) {
      throw const WebhookException.notFound();
    }
    await audit.recordSafely(
        by.event('webhook.updated', target: 'webhook:$id', details: changed));
    return require(id);
  }

  /// Replaces the secret, and returns the new one, which is only available
  /// now.
  Future<String> rotateSecret(String id, {required AuditContext by}) async {
    await require(id);
    final secret = generateSecret();
    if (!await store.update(id, {'secret': secret})) {
      throw const WebhookException.notFound();
    }
    await audit.recordSafely(
        by.event('webhook.secret_rotated', target: 'webhook:$id'));
    return secret;
  }

  Future<void> delete(String id, {required AuditContext by}) async {
    final hook = await require(id);
    if (!await store.delete(id)) throw const WebhookException.notFound();
    await audit.recordSafely(by.event('webhook.deleted',
        target: 'webhook:$id', details: {'url': '${hook.url}'}));
  }

  /// Queues [deliveryId] of [webhookId] again, as a new delivery with the
  /// same payload, and returns that.
  Future<void> redeliver(String webhookId, String deliveryId,
      {required AuditContext by}) async {
    final hook = await require(webhookId);
    final previous = await store.delivery(webhookId, deliveryId);
    if (previous == null) {
      throw const WebhookException.notFound('no such delivery');
    }
    await store.enqueue([hook],
        event: previous.event,
        eventId: previous.eventId,
        payload: previous.payload,
        package: previous.package,
        version: previous.version,
        redeliveryOf: previous.id);
    await audit.recordSafely(by.event('webhook.redelivered',
        target: 'webhook:$webhookId',
        package: previous.package,
        version: previous.version,
        details: {'delivery': previous.id, 'event': previous.event}));
    kick();
  }

  // Events.

  /// The body sent for [event].
  static String payload(WebhookEvent event, String id, DateTime at) =>
      jsonEncode({
        'id': id,
        'event': event.event,
        'at': at.toUtc().toIso8601String(),
        'package': event.package,
        if (event.version != null) 'version': event.version,
        'actor': event.actor,
        'data': event.data,
      });

  /// Queues [event] for every enabled webhook that subscribes to it. A
  /// failure is logged, as the change it reports has already happened.
  Future<void> notify(WebhookEvent event) async {
    if (!config.enabled) return;
    try {
      final hooks = await store.subscribers(event.event);
      if (hooks.isEmpty) return;
      final id = ObjectId().oid;
      await store.enqueue(hooks,
          event: event.event,
          eventId: id,
          payload: payload(event, id, await store.now()),
          package: event.package,
          version: event.version);
      kick();
    } catch (error, stackTrace) {
      _log.severe(
          LogEvent('failed to queue a webhook event',
              {'event': event.event, 'package': event.package}),
          error,
          stackTrace);
    }
  }

  // The worker.

  /// Starts delivering, every [pollInterval] and right after an event.
  void start() {
    if (!config.enabled || !_stopped) return;
    _stopped = false;
    _timer = Timer.periodic(pollInterval, (_) => kick());
    kick();
  }

  /// Stops taking deliveries, and waits for the attempts under way.
  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    if (_lanes == 0) return;
    final idle = Completer<void>();
    _idle.add(idle);
    await idle.future;
  }

  /// Looks for due deliveries now.
  void kick() {
    if (_stopped) return;
    _again = true;
    while (_lanes < concurrency) {
      _lanes++;
      unawaited(_lane());
    }
  }

  /// Sends due deliveries until there are none.
  Future<void> _lane() async {
    try {
      while (!_stopped) {
        _again = false;
        final delivered = await deliverDue();
        if (!delivered && !_again) break;
      }
    } catch (error, stackTrace) {
      _log.warning('webhook worker failed, retrying later', error, stackTrace);
    } finally {
      _lanes--;
      if (_lanes == 0) {
        for (final idle in _idle) {
          idle.complete();
        }
        _idle.clear();
      }
    }
  }

  /// Claims and attempts one due delivery, and returns whether there was one.
  Future<bool> deliverDue() async {
    final delivery = await store.claim(_owner, _lease);
    if (delivery == null) return false;
    await attempt(delivery);
    return true;
  }

  Duration _retryDelay(int attempt) {
    final base = retryDelays[min(attempt - 1, retryDelays.length - 1)];
    final jitter = 0.9 + _random.nextDouble() * 0.2;
    return base * jitter;
  }

  /// Attempts a claimed [delivery] and records the outcome.
  Future<void> attempt(Delivery delivery) async {
    final number = delivery.attempt + 1;
    final hook = await store.find(delivery.webhookId);
    _Outcome outcome;
    if (hook == null || !hook.enabled) {
      outcome = _Outcome.refused(
          hook == null ? 'the webhook was deleted' : 'the webhook is disabled');
    } else {
      outcome = await _send(hook, delivery);
    }

    final String status;
    DateTime? nextAt;
    DeliveryResult result;
    if (outcome.succeeded) {
      status = DeliveryStatus.succeeded;
      result = DeliveryResult.success;
    } else if (outcome.refused) {
      status = DeliveryStatus.failed;
      result = DeliveryResult.refused;
    } else if (number >= config.maxAttempts) {
      status = DeliveryStatus.failed;
      result = DeliveryResult.failed;
    } else {
      status = DeliveryStatus.pending;
      result = DeliveryResult.retry;
      nextAt = (await store.now()).add(_retryDelay(number));
    }
    final recorded = await store.finishAttempt(delivery, _owner,
        status: status,
        attempt: number,
        nextAt: nextAt,
        responseStatus: outcome.status,
        responseBody: outcome.body,
        error: outcome.error);
    if (!recorded) {
      _log.warning(LogEvent(
          'lost the claim of a webhook delivery', {'delivery': delivery.id}));
    }
    onAttempt?.call(result);
    _log.info(LogEvent('webhook delivery attempted', {
      'delivery': delivery.id,
      'event': delivery.event,
      'attempt': number,
      'result': result.name,
      if (outcome.status != null) 'status': outcome.status,
      if (outcome.error != null) 'error': outcome.error,
    }));
  }

  /// The signature header value of [body] with [secret].
  static String signature(String secret, List<int> body) =>
      'sha256=${Hmac(sha256, utf8.encode(secret)).convert(body)}';

  Future<_Outcome> _send(Webhook hook, Delivery delivery) async {
    final url = hook.url;
    final problem = webhookUrlProblem(url, allowHttp: config.allowHttp);
    if (problem != null) return _Outcome.refused(problem);
    final InternetAddress address;
    try {
      address = await resolveWebhookHost(url.host,
              allowPrivate: config.allowPrivateNetworks, lookup: lookup)
          .timeout(config.timeout);
    } on RefusedAddressException catch (error) {
      return _Outcome.refused(error.message);
    } on TimeoutException {
      return const _Outcome.error('resolving the host timed out');
    } on SocketException catch (error) {
      return _Outcome.error('cannot resolve the host: ${error.message}');
    }

    final client = HttpClient()
      ..connectionTimeout = config.timeout
      ..idleTimeout = Duration.zero
      ..autoUncompress = false
      ..userAgent = null
      // Connect to the address checked above, never to a second lookup that
      // could answer differently. TLS still verifies the host name.
      ..connectionFactory = (uri, proxyHost, proxyPort) async {
        final task = await Socket.startConnect(address, uri.port);
        if (uri.scheme != 'https') return task;
        return ConnectionTask.fromSocket(
            task.socket
                .then((socket) => SecureSocket.secure(socket, host: uri.host)),
            task.cancel);
      };
    final body = utf8.encode(delivery.payload);
    try {
      return await _post(client, hook, delivery, body).timeout(config.timeout);
    } on TimeoutException {
      return _Outcome.error(
          'no answer within ${config.timeout.inSeconds} seconds');
    } on SocketException catch (error) {
      return _Outcome.error('connection failed: ${error.message}');
    } on HandshakeException catch (error) {
      return _Outcome.error('TLS handshake failed: ${error.message}');
    } on HttpException catch (error) {
      return _Outcome.error('HTTP error: ${error.message}');
    } finally {
      client.close(force: true);
    }
  }

  Future<_Outcome> _post(HttpClient client, Webhook hook, Delivery delivery,
      List<int> body) async {
    final request = await client.postUrl(hook.url);
    request
      ..followRedirects = false
      ..maxRedirects = 0
      ..persistentConnection = false;
    request.headers
      ..set(HttpHeaders.contentTypeHeader, 'application/json')
      ..set(HttpHeaders.userAgentHeader, 'unpub/$packageVersion')
      ..set('x-unpub-event', delivery.event)
      ..set('x-unpub-delivery', delivery.id)
      ..set('x-unpub-signature', signature(hook.secret, body))
      ..contentLength = body.length;
    request.add(body);
    final response = await request.close();
    final snippet = await _snippet(response);
    final status = response.statusCode;
    if (status >= 200 && status < 300) {
      return _Outcome(status, snippet, succeeded: true);
    }
    return _Outcome(status, snippet,
        error: status >= 300 && status < 400
            ? 'answered with a redirect, which is not followed'
            : 'answered with status $status');
  }

  /// The first [maxResponseSnippet] bytes of the body, decoded leniently. The
  /// rest is not read.
  static Future<String> _snippet(HttpClientResponse response) async {
    final bytes = <int>[];
    final done = Completer<void>();
    late final StreamSubscription<List<int>> subscription;
    subscription = response.listen((chunk) {
      bytes.addAll(chunk.take(maxResponseSnippet - bytes.length));
      if (bytes.length >= maxResponseSnippet && !done.isCompleted) {
        done.complete();
      }
    }, onError: (Object error) {
      if (!done.isCompleted) done.complete();
    }, onDone: () {
      if (!done.isCompleted) done.complete();
    }, cancelOnError: true);
    await done.future;
    await subscription.cancel();
    return utf8.decode(bytes, allowMalformed: true);
  }
}

class _Outcome {
  final int? status;
  final String? body;
  final String? error;
  final bool succeeded;

  /// Whether trying again cannot change the result.
  final bool refused;

  const _Outcome(this.status, this.body, {this.error, this.succeeded = false})
      : refused = false;

  const _Outcome.error(this.error)
      : status = null,
        body = null,
        succeeded = false,
        refused = false;

  const _Outcome.refused(this.error)
      : status = null,
        body = null,
        succeeded = false,
        refused = true;
}
