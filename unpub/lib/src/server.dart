import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:mongo_dart/mongo_dart.dart';

import 'app.dart';
import 'auth/account_api.dart';
import 'auth/account_service.dart';
import 'auth/authenticator.dart';
import 'auth/rate_limiter.dart';
import 'config/config.dart';
import 'logging.dart';
import 'metrics.dart';
import 'publish_policy.dart';
import 'redact.dart';
import 'store/account_store.dart';
import 'store/archive_references.dart';
import 'store/audit_store.dart';
import 'store/file_store.dart';
import 'store/mongo_store.dart';
import 'store/mongo_version.dart';
import 'store/package_store_factory.dart';
import 'store/temporary_reclaimer.dart';
import 'store/upstream_cache_store.dart';
import 'upstream/upstream_proxy.dart';
import 'webhooks/webhook_service.dart';
import 'webhooks/webhook_store.dart';

final _log = Logger('unpub.server');

/// How long in-flight requests may finish before being dropped on shutdown.
const _drainTimeout = Duration(seconds: 30);
const _mongoConnectTimeout = Duration(seconds: 30);

/// A running server built from a [Config].
class UnpubServer {
  final HttpServer _http;
  final Db _db;
  final UpstreamProxy? _upstreamProxy;
  final TemporaryReclaimer _reclaimer;
  final WebhookService _webhooks;
  Future<void>? _stopping;

  UnpubServer._(this._http, this._db, this._upstreamProxy, this._reclaimer,
      this._webhooks);

  int get port => _http.port;

  /// Connects to Mongo, creates the stores, and starts listening.
  ///
  /// An error that quotes the Mongo connection string is rethrown as a
  /// [RedactedException].
  static Future<UnpubServer> start(Config config) async {
    try {
      return await _start(config);
    } catch (error, stackTrace) {
      final original = error.toString();
      final safe = redactConnectionStrings(original);
      if (safe == original) rethrow;
      Error.throwWithStackTrace(RedactedException(safe), stackTrace);
    }
  }

  static Future<UnpubServer> _start(Config config) async {
    final db = await Db.create(config.mongo.uri);
    try {
      await db.open().timeout(_mongoConnectTimeout);
      await checkMongoVersion(db);
      final accounts = AccountStore(db);
      final audit = MongoAuditStore(db);
      final metaStore = MongoStore(db);
      final upstreamCache = MongoUpstreamCacheStore(db);
      await accounts.ensureIndexes();
      await audit.ensureIndexes(retention: config.audit.retention);
      await metaStore.ensureIndexes();
      await upstreamCache.ensureIndexes();
      final webhookStore = WebhookStore(db);
      await webhookStore.ensureIndexes(retention: config.webhooks.retention);
      final metrics = Metrics();
      final webhooks = WebhookService(webhookStore,
          config: config.webhooks,
          audit: audit,
          onAttempt: (result) => metrics.countWebhookDelivery(result.name));
      final service = AccountService(accounts, audit: audit);
      await service.bootstrapAdmin(config.auth.admin);
      await accounts.reconcileAdminSet(DateTime.now());
      _warnAboutStaticTokens(config.auth);
      _warnAboutUnusedAllowlist(config.upstream);

      final packageStore = await createPackageStore(config.storage);
      if (packageStore is FileStore) {
        final created = await packageStore.createBaseDir();
        _log.info(LogEvent(
            created ? 'created storage directory' : 'using storage directory',
            {'path': packageStore.baseDir}));
      }

      final upstreamProxy = config.upstream.mode == UpstreamMode.proxy
          ? UpstreamProxy(
              config: config.upstream,
              cache: upstreamCache,
              archives: packageStore,
              onFetch: metrics.countUpstreamFetch,
            )
          : null;

      final app = App(
        metaStore: metaStore,
        packageStore: packageStore,
        authenticator: ChainAuthenticator([
          ApiTokenAuthenticator(accounts),
          SessionAuthenticator(accounts),
          StaticTokenAuthenticator(
            bootstrapToken: config.auth.bootstrapToken,
            bootstrapEmail: config.auth.bootstrapEmail,
            readTokens: config.auth.readTokens.toSet(),
          ),
        ]),
        readAccess: config.auth.readAccess,
        accountApi: AccountApi(
          service,
          limiter: LoginRateLimiter(),
          secureCookies: config.server.publicUrl?.scheme == 'https',
          trustForwardedFor: config.server.trustForwardedFor,
        ),
        auditStore: audit,
        webhooks: webhooks,
        trustForwardedFor: config.server.trustForwardedFor,
        upstream: config.upstream.url.toString(),
        upstreamProxy: upstreamProxy,
        publishPolicy: PublishPolicy(config.publish),
        publicUrl: config.server.publicUrl,
        config: config,
        metrics: metrics,
      );
      final http = await app.serve(config.server.host, config.server.port);
      final reclaimer = TemporaryReclaimer(packageStore,
          references: MongoArchiveReferences(db))
        ..start();
      webhooks.start();
      return UnpubServer._(http, db, upstreamProxy, reclaimer, webhooks);
    } catch (_) {
      await db.close().catchError((Object _) {});
      rethrow;
    }
  }

  static void _warnAboutUnusedAllowlist(UpstreamConfig upstream) {
    if (upstream.mode == UpstreamMode.redirect &&
        upstream.allowlist.isNotEmpty) {
      _log.warning('upstream.allowlist only applies when upstream.mode is '
          'proxy, every unknown package is redirected');
    }
  }

  static void _warnAboutStaticTokens(AuthConfig auth) {
    if (auth.bootstrapToken != null) {
      _log.warning('auth.bootstrapToken is deprecated, use a personal token '
          'from unpub admin create-token');
    }
    if (auth.readTokens.isNotEmpty) {
      _log.warning('auth.readTokens is deprecated, use personal tokens with '
          'the read scope');
    }
  }

  /// Stops accepting connections, drains in-flight requests, and closes Mongo.
  Future<void> stop() => _stopping ??= _stop();

  Future<void> _stop() async {
    _log.info('shutting down');
    try {
      await _http.close().timeout(_drainTimeout);
    } on TimeoutException {
      _log.warning('dropping requests still running after drain timeout');
      await _http.close(force: true);
    }
    _upstreamProxy?.close();
    _reclaimer.stop();
    await _webhooks.stop().timeout(_drainTimeout, onTimeout: () {
      _log.warning('dropping webhook deliveries still running');
    });
    await _db.close();
    _log.info('stopped');
  }

  /// Completes after the first SIGINT or SIGTERM once [stop] has finished.
  ///
  /// A second signal exits immediately.
  Future<void> waitForShutdown() async {
    final signals = [
      ProcessSignal.sigint,
      if (!Platform.isWindows) ProcessSignal.sigterm,
    ];
    final done = Completer<void>();
    final subscriptions = <StreamSubscription<ProcessSignal>>[];
    for (final signal in signals) {
      subscriptions.add(signal.watch().listen((received) {
        if (done.isCompleted || _stopping != null) {
          _log.warning('received $received again, exiting immediately');
          exit(130);
        }
        _log.info('received $received');
        stop().then(done.complete, onError: done.completeError);
      }));
    }
    try {
      await done.future;
    } finally {
      await Future.wait(subscriptions.map((s) => s.cancel()));
    }
  }
}
