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
import 'redact.dart';
import 'store/account_store.dart';
import 'store/audit_store.dart';
import 'store/aws_credentials.dart';
import 'store/file_store.dart';
import 'store/mongo_store.dart';
import 'store/mongo_version.dart';
import 'store/package_store.dart';
import 'store/s3_store.dart';

final _log = Logger('unpub.server');

/// How long in-flight requests may finish before being dropped on shutdown.
const _drainTimeout = Duration(seconds: 30);
const _mongoConnectTimeout = Duration(seconds: 30);

/// A running server built from a [Config].
class UnpubServer {
  final HttpServer _http;
  final Db _db;
  Future<void>? _stopping;

  UnpubServer._(this._http, this._db);

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
      await accounts.ensureIndexes();
      await audit.ensureIndexes();
      final service = AccountService(accounts, audit: audit);
      await service.bootstrapAdmin(config.auth.admin);
      await accounts.reconcileAdminSet(DateTime.now());
      _warnAboutStaticTokens(config.auth);

      final app = App(
        metaStore: MongoStore(db),
        packageStore: await _createPackageStore(config.storage),
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
        trustForwardedFor: config.server.trustForwardedFor,
        upstream: config.upstream.url.toString(),
        publicUrl: config.server.publicUrl,
      );
      final http = await app.serve(config.server.host, config.server.port);
      return UnpubServer._(http, db);
    } catch (_) {
      await db.close().catchError((Object _) {});
      rethrow;
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

  static Future<PackageStore> _createPackageStore(StorageConfig storage) async {
    final s3 = storage.s3;
    if (s3 == null) {
      final path = storage.file.path;
      final store = FileStore(path);
      final created = await store.createBaseDir();
      _log.info(LogEvent(
          created ? 'created storage directory' : 'using storage directory',
          {'path': path}));
      return store;
    }
    return S3Store(
      s3.bucket,
      region: s3.region,
      endpoint: s3.endpoint,
      port: s3.port,
      useSSL: s3.useSSL,
      pathStyle: s3.pathStyle,
      credentials: await AwsCredentials.resolve(
        accessKeyId: s3.accessKey,
        secretAccessKey: s3.secretKey,
        sessionToken: s3.sessionToken,
      ),
    );
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
