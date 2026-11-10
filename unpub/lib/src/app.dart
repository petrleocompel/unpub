import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_cors_headers/shelf_cors_headers.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth/account_api.dart';
import 'auth/auth_middleware.dart';
import 'auth/authenticator.dart';
import 'config/config.dart';
import 'publish_policy.dart';
import 'request_logger.dart';
import 'routes/admin_api_routes.dart';
import 'routes/badge_routes.dart';
import 'routes/health_routes.dart';
import 'routes/moderation_routes.dart';
import 'routes/pub_api_routes.dart';
import 'routes/publish_routes.dart';
import 'routes/webapi_routes.dart';
import 'store/audit_store.dart';
import 'store/meta_store.dart';
import 'store/package_store.dart';
import 'upstream/upstream_proxy.dart';
import 'web/web_ui.dart';

class App {
  /// meta information store
  final MetaStore metaStore;

  /// package(tarball) store
  final PackageStore packageStore;

  /// upstream url, default: https://pub.dev
  final String upstream;

  /// Establishes the identity behind each request.
  final Authenticator authenticator;

  /// Whether reading needs credentials.
  final ReadAccess readAccess;

  /// The account endpoints under `/webapi`, absent when embedding without
  /// user accounts.
  final AccountApi? accountApi;

  /// Records publishes and uploader changes.
  final AuditStore auditStore;

  /// Whether the client address is taken from `X-Forwarded-For`.
  final bool trustForwardedFor;

  /// External URL of this server. When null, URLs derive from the request.
  final Uri? publicUrl;

  /// Fetches packages from the upstream instead of redirecting to it.
  final UpstreamProxy? upstreamProxy;

  /// The `publish` rules uploads must satisfy.
  final PublishPolicy publishPolicy;

  /// validate if the package can be published
  ///
  /// Runs after the [publishPolicy], and only for an upload that passes it.
  final Future<void> Function(
      Map<String, dynamic> pubspec, String uploaderEmail)? uploadValidator;

  /// The effective configuration, shown read-only on the admin settings
  /// page with its secrets redacted. Absent when embedding without one.
  final Config? config;

  /// Holds the uploads in progress, so it lives as long as the app.
  late final _publishRoutes = PublishRoutes(this);

  late final _webUi = WebUi(this);

  App({
    required this.metaStore,
    required this.packageStore,
    required this.authenticator,
    this.readAccess = ReadAccess.public,
    this.accountApi,
    this.auditStore = const NullAuditStore(),
    this.trustForwardedFor = false,
    this.upstream = 'https://pub.dev',
    this.upstreamProxy,
    this.publishPolicy = const PublishPolicy(PublishConfig()),
    this.uploadValidator,
    this.publicUrl,
    this.config,
  });

  /// The complete request handler, including all middleware.
  shelf.Handler get handler => const shelf.Pipeline()
      // Bearer tokens work cross-origin, but a session cookie must not: this
      // middleware echoes the origin, so credentialed requests stay disabled.
      .addMiddleware(
          corsHeaders(headers: {'Access-Control-Allow-Credentials': 'false'}))
      .addMiddleware(requestLogger())
      .addMiddleware(authMiddleware(authenticator,
          readAccess: readAccess, failureResponse: _webUi.authFailure))
      .addMiddleware(_webUi.errorPages)
      .addHandler(router.call);

  Future<HttpServer> serve([String host = '0.0.0.0', int port = 4000]) {
    return shelf_io.serve(handler, host, port);
  }

  bool isPubClient(shelf.Request req) {
    var ua = req.headers[HttpHeaders.userAgentHeader];
    return ua != null && ua.toLowerCase().contains('dart pub');
  }

  /// Every route, without the middleware of [handler]. Routes are matched in
  /// the order they are added.
  Router get router {
    final router = Router(notFoundHandler: _webUi.notFound);
    HealthRoutes(this).addRoutes(router);
    PubApiRoutes(this).addRoutes(router);
    _publishRoutes.addRoutes(router);
    ModerationRoutes(this).addRoutes(router);
    WebapiRoutes(this).addRoutes(router);
    AdminApiRoutes(this).addRoutes(router);
    _webUi.addRoutes(router);
    BadgeRoutes(this).addRoutes(router);
    accountApi?.addRoutes(router);
    return router;
  }
}
