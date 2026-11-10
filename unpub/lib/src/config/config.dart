import 'dart:io';

import 'package:logging/logging.dart';
import 'package:yaml/yaml.dart';

import '../auth/accounts.dart';
import '../logging.dart';
import '../validation.dart';

/// Raised when the configuration cannot be loaded or is invalid.
///
/// [problems] lists every issue found, not only the first one.
class ConfigException implements Exception {
  final List<String> problems;

  const ConfigException(this.problems);

  @override
  String toString() => 'Invalid configuration:\n'
      '${problems.map((problem) => '  - $problem').join('\n')}';
}

enum _ValueKind { string, stringList, integer, boolean }

/// Every key the configuration file and environment accept.
const _schema = <String, _ValueKind>{
  'server.host': _ValueKind.string,
  'server.port': _ValueKind.integer,
  'server.publicUrl': _ValueKind.string,
  'server.trustForwardedFor': _ValueKind.boolean,
  'mongo.uri': _ValueKind.string,
  'storage.type': _ValueKind.string,
  'storage.file.path': _ValueKind.string,
  'storage.s3.bucket': _ValueKind.string,
  'storage.s3.region': _ValueKind.string,
  'storage.s3.endpoint': _ValueKind.string,
  'storage.s3.port': _ValueKind.integer,
  'storage.s3.useSSL': _ValueKind.boolean,
  'storage.s3.pathStyle': _ValueKind.boolean,
  'storage.s3.accessKey': _ValueKind.string,
  'storage.s3.secretKey': _ValueKind.string,
  'storage.s3.sessionToken': _ValueKind.string,
  'upstream.url': _ValueKind.string,
  'upstream.mode': _ValueKind.string,
  'upstream.cacheTtl': _ValueKind.string,
  'upstream.allowlist': _ValueKind.stringList,
  'upstream.timeout': _ValueKind.string,
  'upstream.allowedArchiveHosts': _ValueKind.stringList,
  'upstream.requireSha256': _ValueKind.boolean,
  'upstream.allowPublishWhenUnavailable': _ValueKind.boolean,
  'upstream.maxArchiveBytes': _ValueKind.integer,
  'upstream.maxConcurrentFetches': _ValueKind.integer,
  'publish.allowedNamePrefixes': _ValueKind.stringList,
  'publish.maxArchiveBytes': _ValueKind.integer,
  'publish.maxUnpackedBytes': _ValueKind.integer,
  'publish.requiredFiles': _ValueKind.stringList,
  'publish.rejectOlderThanLatest': _ValueKind.boolean,
  'publish.requireVersionBump': _ValueKind.boolean,
  'publish.retractionWindow': _ValueKind.string,
  'publish.uploadTimeout': _ValueKind.string,
  'auth.bootstrapToken': _ValueKind.string,
  'auth.bootstrapEmail': _ValueKind.string,
  'auth.readAccess': _ValueKind.string,
  'auth.readTokens': _ValueKind.stringList,
  'auth.admin.email': _ValueKind.string,
  'auth.admin.password': _ValueKind.string,
  'audit.retentionDays': _ValueKind.integer,
  'webhooks.enabled': _ValueKind.boolean,
  'webhooks.timeout': _ValueKind.string,
  'webhooks.maxAttempts': _ValueKind.integer,
  'webhooks.allowHttp': _ValueKind.boolean,
  'webhooks.allowPrivateNetworks': _ValueKind.boolean,
  'webhooks.retentionDays': _ValueKind.integer,
  'metrics.enabled': _ValueKind.boolean,
  'metrics.token': _ValueKind.string,
  'ui.assetsDir': _ValueKind.string,
  'ui.mode': _ValueKind.string,
  'logging.level': _ValueKind.string,
  'logging.format': _ValueKind.string,
};

/// The environment variable that sets [key], such as
/// `UNPUB_SERVER_PUBLIC_URL` for `server.publicUrl`.
String environmentVariableFor(String key) {
  final words = [
    for (final part in key.split('.'))
      part.replaceAllMapped(RegExp(r'(?<=[a-z0-9])(?=[A-Z])'), (_) => '_'),
  ];
  return 'UNPUB_${words.join('_').toUpperCase()}';
}

/// Keys whose values must never appear in messages.
const _secretKeys = {
  'storage.s3.accessKey',
  'storage.s3.secretKey',
  'storage.s3.sessionToken',
  'auth.bootstrapToken',
  'auth.readTokens',
  'auth.admin.password',
  'metrics.token',
  'mongo.uri',
};

const _logLevels = <String, Level>{
  'all': Level.ALL,
  'finest': Level.FINEST,
  'finer': Level.FINER,
  'fine': Level.FINE,
  'debug': Level.FINE,
  'config': Level.CONFIG,
  'info': Level.INFO,
  'warning': Level.WARNING,
  'warn': Level.WARNING,
  'severe': Level.SEVERE,
  'error': Level.SEVERE,
  'shout': Level.SHOUT,
  'off': Level.OFF,
};

/// The characters `dart pub token add` accepts in a Bearer token.
final _bearerTokenPattern = RegExp(r'^[a-zA-Z0-9._~+/=-]+$');
final _mongoScheme = RegExp(r'^mongodb(\+srv)?://');
final _whitespaceOrControl = RegExp(r'[\s\x00-\x1f\x7f]');

/// Why mongo_dart cannot use [uri], or null if it can.
///
/// Parsing here gives messages that never quote the URI, while the driver's
/// own errors repeat it, password included. `Uri` alone cannot do this because
/// a standard connection string can list several hosts.
String? _mongoUriProblem(String uri) {
  if (_whitespaceOrControl.hasMatch(uri)) {
    return 'it contains whitespace or control characters';
  }
  final scheme = _mongoScheme.firstMatch(uri);
  if (scheme == null) return 'the scheme must be mongodb or mongodb+srv';

  final rest = uri.substring(scheme.end);
  final slash = rest.indexOf('/');
  if (slash < 0) return 'the database name is required';
  final authority = rest.substring(0, slash);
  final tail = rest.substring(slash + 1);
  final database = tail.split('?').first;
  if (database.isEmpty || database.contains('/')) {
    return 'the database name is required';
  }

  final at = authority.lastIndexOf('@');
  final userInfo = at < 0 ? null : authority.substring(0, at);
  if (userInfo != null) {
    final parts = userInfo.split(':');
    if (parts.length != 2 || parts.first.isEmpty || userInfo.contains('@')) {
      return 'the credentials must be user:password, with reserved characters '
          'percent-encoded';
    }
  }

  final hosts = authority.substring(at + 1).split(',');
  if (scheme.group(1) != null &&
      (hosts.length != 1 || hosts.single.contains(':'))) {
    return 'mongodb+srv takes a single host name without a port';
  }
  final credentials = userInfo == null ? '' : '$userInfo@';
  for (final host in hosts) {
    final parsed = Uri.tryParse('mongodb://$credentials$host/$tail');
    if (parsed == null ||
        parsed.host.isEmpty ||
        (parsed.hasPort && parsed.port > 65535)) {
      return 'a host or port is invalid';
    }
  }
  return null;
}

class ServerConfig {
  final String host;
  final int port;

  /// External URL of this server, used to build absolute URLs.
  ///
  /// When null, URLs are derived from the request.
  final Uri? publicUrl;

  /// Whether the client address is taken from `X-Forwarded-For`. Only safe
  /// behind a reverse proxy that sets the header.
  final bool trustForwardedFor;

  const ServerConfig({
    required this.host,
    required this.port,
    required this.publicUrl,
    this.trustForwardedFor = false,
  });
}

class MongoConfig {
  final String uri;

  const MongoConfig({required this.uri});
}

enum StorageType { file, s3 }

class FileStorageConfig {
  final String path;

  const FileStorageConfig({required this.path});
}

class S3StorageConfig {
  final String bucket;
  final String region;
  final String endpoint;
  final int? port;
  final bool useSSL;
  final bool? pathStyle;
  final String? accessKey;
  final String? secretKey;
  final String? sessionToken;

  const S3StorageConfig({
    required this.bucket,
    required this.region,
    required this.endpoint,
    required this.port,
    required this.useSSL,
    required this.pathStyle,
    required this.accessKey,
    required this.secretKey,
    required this.sessionToken,
  });
}

class StorageConfig {
  final StorageType type;
  final FileStorageConfig file;

  /// Set only when [type] is [StorageType.s3].
  final S3StorageConfig? s3;

  const StorageConfig({
    required this.type,
    required this.file,
    required this.s3,
  });
}

/// What happens to a package that does not exist locally.
enum UpstreamMode {
  /// Send the client to the upstream.
  redirect,

  /// Fetch from the upstream and keep a copy.
  proxy,
}

class UpstreamConfig {
  static const defaultCacheTtl = Duration(minutes: 10);
  static const defaultTimeout = Duration(seconds: 30);
  static const defaultMaxArchiveBytes = 256 * 1024 * 1024;
  static const defaultMaxConcurrentFetches = 4;

  final Uri url;
  final UpstreamMode mode;

  /// How long proxied metadata is served without asking the upstream again.
  final Duration cacheTtl;

  /// The only packages proxied, or empty for any package.
  final List<String> allowlist;

  /// How long an upstream may stay silent during a request.
  final Duration timeout;

  /// Hosts besides that of [url] that archives may be fetched from.
  final List<String> allowedArchiveHosts;

  /// Refuse an archive the upstream gives no hash for. When false, it is
  /// served and cached unverified.
  final bool requireSha256;

  /// Accept a new package name, with a warning, when the upstream cannot say
  /// whether it has that name. Off by default, because a name published during
  /// an outage would shadow the upstream package from then on.
  final bool allowPublishWhenUnavailable;

  /// Largest archive fetched from the upstream.
  final int maxArchiveBytes;

  /// How many archives are fetched at once. Other first downloads wait.
  final int maxConcurrentFetches;

  const UpstreamConfig({
    required this.url,
    this.mode = UpstreamMode.redirect,
    this.cacheTtl = defaultCacheTtl,
    this.allowlist = const [],
    this.timeout = defaultTimeout,
    this.allowedArchiveHosts = const [],
    this.requireSha256 = true,
    this.allowPublishWhenUnavailable = false,
    this.maxArchiveBytes = defaultMaxArchiveBytes,
    this.maxConcurrentFetches = defaultMaxConcurrentFetches,
  });
}

/// How long a claim on publishing a version lasts unless it is renewed.
const uploadReservationTtl = Duration(minutes: 15);

/// Rules an upload must satisfy.
class PublishConfig {
  static const defaultMaxArchiveBytes = 100 * 1024 * 1024;
  static const defaultMaxUnpackedBytes = 512 * 1024 * 1024;
  static const defaultUploadTimeout = Duration(minutes: 10);

  /// Package names must start with one of these, or empty for any name.
  final List<String> allowedNamePrefixes;
  final int maxArchiveBytes;

  /// Largest size an archive may inflate to, against compression bombs.
  final int maxUnpackedBytes;

  /// Files the archive must hold at its root, matched ignoring case.
  final List<String> requiredFiles;

  /// Refuse a version lower than the highest one not retracted.
  final bool rejectOlderThanLatest;

  /// Refuse a version that already exists. When false, publishing an existing
  /// version replaces it.
  final bool requireVersionBump;

  /// How long after publishing a non-administrator may retract, or null for
  /// no limit.
  final Duration? retractionWindow;

  /// How long storing an archive may take. It stays below
  /// [uploadReservationTtl], so that a stalled write fails first.
  final Duration uploadTimeout;

  const PublishConfig({
    this.allowedNamePrefixes = const [],
    this.maxArchiveBytes = defaultMaxArchiveBytes,
    this.maxUnpackedBytes = defaultMaxUnpackedBytes,
    this.requiredFiles = const [],
    this.rejectOlderThanLatest = false,
    this.requireVersionBump = true,
    this.retractionWindow = const Duration(days: 7),
    this.uploadTimeout = defaultUploadTimeout,
  });
}

/// Who may read packages.
enum ReadAccess { public, authenticated }

/// The administrator created at startup when there are no users yet.
class AdminBootstrapConfig {
  final String email;
  final String password;

  const AdminBootstrapConfig({required this.email, required this.password});
}

class AuthConfig {
  /// Deprecated static Bearer token that acts as an administrator.
  final String? bootstrapToken;

  /// Email of the identity behind [bootstrapToken].
  final String bootstrapEmail;

  final ReadAccess readAccess;

  /// Deprecated static Bearer tokens that act as a reader.
  final List<String> readTokens;

  /// Set when `auth.admin.email` and `auth.admin.password` are configured.
  final AdminBootstrapConfig? admin;

  const AuthConfig({
    required this.bootstrapToken,
    required this.bootstrapEmail,
    this.readAccess = ReadAccess.public,
    this.readTokens = const [],
    this.admin,
  });
}

/// How long the audit trail is kept.
class AuditConfig {
  /// Days after which an event is deleted, or 0 to keep every event.
  final int retentionDays;

  const AuditConfig({this.retentionDays = 0});

  /// Null when events are kept for good.
  Duration? get retention =>
      retentionDays > 0 ? Duration(days: retentionDays) : null;
}

/// How webhooks are delivered.
class WebhooksConfig {
  static const defaultTimeout = Duration(seconds: 10);
  static const defaultMaxAttempts = 5;
  static const defaultRetentionDays = 30;

  /// Whether events are queued and delivered at all.
  final bool enabled;

  /// How long one delivery attempt may take.
  final Duration timeout;

  /// Attempts before a delivery is given up as failed.
  final int maxAttempts;

  /// Whether a webhook URL may use plain http.
  final bool allowHttp;

  /// Whether a webhook may reach loopback, link-local, private and unique
  /// local addresses.
  final bool allowPrivateNetworks;

  /// Days a finished delivery is kept, or 0 to keep every delivery.
  final int retentionDays;

  const WebhooksConfig({
    this.enabled = true,
    this.timeout = defaultTimeout,
    this.maxAttempts = defaultMaxAttempts,
    this.allowHttp = false,
    this.allowPrivateNetworks = false,
    this.retentionDays = defaultRetentionDays,
  });

  /// Null when deliveries are kept for good.
  Duration? get retention =>
      retentionDays > 0 ? Duration(days: retentionDays) : null;
}

/// The Prometheus endpoint `/metrics`.
class MetricsConfig {
  final bool enabled;

  /// A Bearer token that opens `/metrics`, for a scraper without an account.
  final String? token;

  const MetricsConfig({this.enabled = true, this.token});
}

/// Which user interface the server shows at `/`.
enum UiMode {
  /// The single-page client at `/`, the server-rendered pages under
  /// `/classic`.
  spa,

  /// The server-rendered pages at `/`, the single-page client, if its files
  /// exist, under `/app`.
  ssr,
}

/// The web client and where its built files are.
class UiConfig {
  /// Where `ui.assetsDir` is looked for when it is not set, in order: the
  /// directory of the Docker image, then the build output of a checkout,
  /// relative to the working directory.
  static const defaultAssetDirs = ['/app/ui', 'ui/dist'];

  /// The directory holding `index.html` and `assets/`, or null when there is
  /// no client to serve.
  final String? assetsDir;
  final UiMode mode;

  const UiConfig({this.assetsDir, this.mode = UiMode.ssr});

  /// Whether the single-page client is served.
  bool get hasAssets => assetsDir != null;

  /// The path the single-page client is served under, `''` for `/`.
  String get spaBasePath => mode == UiMode.spa ? '' : '/app';

  /// The path the server-rendered pages are served under, `''` for `/`.
  String get classicBasePath => mode == UiMode.spa ? '/classic' : '';

  /// Whether [directory] holds a built client.
  static bool isClientDirectory(String directory) =>
      File('$directory${Platform.pathSeparator}index.html').existsSync();
}

class LoggingConfig {
  final Level level;
  final LogFormat format;

  const LoggingConfig({required this.level, required this.format});
}

/// Where the value of a configuration key came from.
enum ConfigSource {
  /// Not set anywhere: the built-in default.
  defaults('default'),

  /// The YAML file.
  file('file'),

  /// An `UNPUB_*` environment variable.
  environment('env'),

  /// A command-line flag, such as `--port`.
  flag('flag');

  /// The name the settings API uses.
  final String label;

  const ConfigSource(this.label);
}

/// Validated server configuration.
///
/// Values are resolved from, in increasing precedence: built-in defaults, the
/// YAML file, `UNPUB_<SECTION>_<KEY>` environment variables, and CLI flags.
class Config {
  /// Config file used when `--config` is not given. It may be absent.
  static const defaultPath = 'unpub.yaml';

  final ServerConfig server;
  final MongoConfig mongo;
  final StorageConfig storage;
  final UpstreamConfig upstream;
  final PublishConfig publish;
  final AuthConfig auth;
  final AuditConfig audit;
  final WebhooksConfig webhooks;
  final MetricsConfig metrics;
  final UiConfig ui;
  final LoggingConfig logging;

  /// Where each key that is not at its default came from, by dotted key.
  final Map<String, ConfigSource> sources;

  const Config({
    required this.server,
    required this.mongo,
    required this.storage,
    required this.upstream,
    this.publish = const PublishConfig(),
    required this.auth,
    this.audit = const AuditConfig(),
    this.webhooks = const WebhooksConfig(),
    this.metrics = const MetricsConfig(),
    this.ui = const UiConfig(),
    required this.logging,
    this.sources = const {},
  });

  /// Where the value of the dotted [key] came from.
  ConfigSource sourceOf(String key) => sources[key] ?? ConfigSource.defaults;

  /// Reads the file at [path] and resolves the configuration.
  ///
  /// When [path] is null, [defaultPath] is used if it exists. An explicit
  /// [path] must exist.
  static Config load({
    String? path,
    Map<String, String>? environment,
    String? host,
    String? port,
  }) {
    final file = File(path ?? defaultPath);
    String? content;
    if (file.existsSync()) {
      try {
        content = file.readAsStringSync();
      } on FileSystemException catch (error) {
        throw ConfigException(
            ['cannot read config file ${file.path}: ${error.message}']);
      }
    } else if (path != null) {
      throw ConfigException(['config file not found: $path']);
    }
    return parse(
      content,
      sourceName: file.path,
      environment: environment,
      host: host,
      port: port,
    );
  }

  /// Resolves the configuration from YAML text.
  static Config parse(
    String? yamlText, {
    String sourceName = defaultPath,
    Map<String, String>? environment,
    String? host,
    String? port,
  }) {
    final env = environment ?? Platform.environment;
    final reader = _ConfigReader(env);
    reader.addYaml(yamlText, sourceName);
    reader.addEnvironment(env);
    reader.addOverride('server.host', host, '--host');
    reader.addOverride('server.port', port, '--port');
    return reader.build();
  }
}

class _ConfigReader {
  final Map<String, String> _environment;
  final _values = <String, Object>{};
  final _sources = <String, String>{};
  final _kinds = <String, ConfigSource>{};
  final _problems = <String>[];

  _ConfigReader(this._environment);

  void addYaml(String? text, String sourceName) {
    if (text == null || text.trim().isEmpty) return;
    final Object? document;
    try {
      document = loadYaml(text, sourceUrl: Uri.file(sourceName));
    } on YamlException catch (error) {
      _problems.add('cannot parse $sourceName: ${error.message} '
          '(line ${(error.span?.start.line ?? 0) + 1})');
      return;
    }
    if (document == null) return;
    if (document is! YamlMap) {
      _problems.add('$sourceName must contain a YAML mapping');
      return;
    }
    _flatten(document, '', sourceName);
  }

  void _flatten(YamlMap map, String prefix, String sourceName) {
    for (final entry in map.entries) {
      final key = '$prefix${entry.key}';
      final value = entry.value;
      if (value is YamlMap) {
        if (_isSection(key)) {
          _flatten(value, '$key.', sourceName);
        } else {
          _problems.add('unknown section "$key" in $sourceName');
        }
      } else if (_schema.containsKey(key)) {
        if (value != null) {
          _values[key] = value as Object;
          _sources[key] = sourceName;
          _kinds[key] = ConfigSource.file;
        }
      } else if (!(value == null && _isSection(key))) {
        _problems.add('unknown key "$key" in $sourceName');
      }
    }
  }

  bool _isSection(String key) =>
      _schema.keys.any((candidate) => candidate.startsWith('$key.'));

  /// Applies `UNPUB_*` variables. Underscores are ignored when matching, so
  /// `UNPUB_SERVER_PUBLIC_URL` and `UNPUB_SERVER_PUBLICURL` are equivalent.
  ///
  /// Unknown variables are ignored because orchestrators inject others, such
  /// as Kubernetes' `UNPUB_SERVICE_HOST`.
  void addEnvironment(Map<String, String> environment) {
    final keysByEnvName = {
      for (final key in _schema.keys)
        key.replaceAll('.', '').toUpperCase(): key,
    };
    final names = environment.keys.where((n) => n.startsWith('UNPUB_')).toList()
      ..sort();
    for (final name in names) {
      final normalized = name.substring('UNPUB_'.length).replaceAll('_', '');
      final key = keysByEnvName[normalized];
      final value = environment[name]!;
      if (key != null && value.isNotEmpty) {
        _values[key] = value;
        _sources[key] = name;
        _kinds[key] = ConfigSource.environment;
      }
    }
  }

  void addOverride(String key, String? value, String source) {
    if (value == null) return;
    _values[key] = value;
    _sources[key] = source;
    _kinds[key] = ConfigSource.flag;
  }

  String _describe(String key) {
    final source = _sources[key];
    return source == null ? key : '$key (from $source)';
  }

  String _shown(String key) =>
      _secretKeys.contains(key) ? '<redacted>' : '"${_values[key]}"';

  String? _string(String key) {
    assert(_schema[key] == _ValueKind.string);
    final value = _values[key];
    if (value == null) return null;
    if (value is String || value is num || value is bool) {
      final text = value.toString();
      return text.isEmpty ? null : text;
    }
    _problems.add('${_describe(key)} must be a string');
    return null;
  }

  /// A YAML list, or a comma separated string as environment variables use.
  List<String> _stringList(String key) {
    assert(_schema[key] == _ValueKind.stringList);
    final value = _values[key];
    if (value == null) return const [];
    final items = switch (value) {
      String() => value.split(','),
      YamlList() => value.map((item) => '$item').toList(),
      _ => null,
    };
    if (items == null ||
        (value is YamlList && value.any((item) => item is! String))) {
      _problems.add('${_describe(key)} must be a list of strings');
      return const [];
    }
    return [
      for (final item in items)
        if (item.trim().isNotEmpty) item.trim(),
    ];
  }

  int? _integer(String key) {
    assert(_schema[key] == _ValueKind.integer);
    final value = _values[key];
    if (value == null) return null;
    final parsed = value is int ? value : int.tryParse(value.toString());
    if (parsed == null) {
      _problems.add('${_describe(key)} must be an integer, got ${_shown(key)}');
    }
    return parsed;
  }

  bool? _boolean(String key) {
    assert(_schema[key] == _ValueKind.boolean);
    final value = _values[key];
    if (value == null) return null;
    if (value is bool) return value;
    switch (value.toString().toLowerCase()) {
      case 'true':
        return true;
      case 'false':
        return false;
    }
    _problems
        .add('${_describe(key)} must be true or false, got ${_shown(key)}');
    return null;
  }

  Uri? _httpUrl(String key) {
    final text = _string(key);
    if (text == null) return null;
    final uri = Uri.tryParse(text);
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      _problems.add(
          '${_describe(key)} must be an absolute http(s) URL, got ${_shown(key)}');
      return null;
    }
    return uri;
  }

  Uri? _publicUrl() {
    final uri = _httpUrl('server.publicUrl');
    if (uri == null) return null;
    if (uri.hasQuery ||
        uri.hasFragment ||
        !(uri.path == '' || uri.path == '/')) {
      _problems.add('${_describe('server.publicUrl')} must be an origin such '
          'as https://pub.example.com, without a path, query or fragment');
      return null;
    }
    return uri;
  }

  Config build() {
    final server = ServerConfig(
      host: _string('server.host') ?? '0.0.0.0',
      port: _port(),
      publicUrl: _publicUrl(),
      trustForwardedFor: _boolean('server.trustForwardedFor') ?? false,
    );
    final mongo = MongoConfig(uri: _mongoUri());
    final storage = _storage();
    final upstream = _upstream();
    final publish = _publish();
    final auth = _auth();
    final audit = _audit();
    final webhooks = _webhooks();
    final metrics = _metrics();
    final ui = _ui();
    final logging = _logging();
    if (_problems.isNotEmpty) throw ConfigException(_problems);
    return Config(
      server: server,
      mongo: mongo,
      storage: storage,
      upstream: upstream,
      publish: publish,
      auth: auth,
      audit: audit,
      webhooks: webhooks,
      metrics: metrics,
      ui: ui,
      logging: logging,
      sources: Map.unmodifiable(_kinds),
    );
  }

  /// The most days a retention setting may hold, 100 years, so that the
  /// duration it makes can never overflow into a negative one.
  static const maxRetentionDays = 36500;

  /// A number of days, 0 to [maxRetentionDays], with [fallback] when unset.
  int _days(String key, int fallback) {
    final days = _integer(key);
    if (days != null && (days < 0 || days > maxRetentionDays)) {
      _problems
          .add('${_describe(key)} must be between 0 and $maxRetentionDays');
      return fallback;
    }
    return days ?? fallback;
  }

  AuditConfig _audit() =>
      AuditConfig(retentionDays: _days('audit.retentionDays', 0));

  WebhooksConfig _webhooks() {
    final attempts = _integer('webhooks.maxAttempts');
    if (attempts != null && (attempts < 1 || attempts > 20)) {
      _problems.add('${_describe('webhooks.maxAttempts')} must be between 1 '
          'and 20');
    }
    final timeout = _duration('webhooks.timeout', allowZero: false);
    if (timeout != null && timeout > const Duration(minutes: 5)) {
      _problems
          .add('${_describe('webhooks.timeout')} must be at most 5 minutes');
    }
    return WebhooksConfig(
      enabled: _boolean('webhooks.enabled') ?? true,
      timeout: timeout ?? WebhooksConfig.defaultTimeout,
      maxAttempts: attempts ?? WebhooksConfig.defaultMaxAttempts,
      allowHttp: _boolean('webhooks.allowHttp') ?? false,
      allowPrivateNetworks: _boolean('webhooks.allowPrivateNetworks') ?? false,
      retentionDays:
          _days('webhooks.retentionDays', WebhooksConfig.defaultRetentionDays),
    );
  }

  MetricsConfig _metrics() {
    final token = _string('metrics.token');
    if (token != null && !_bearerTokenPattern.hasMatch(token)) {
      _problems.add('${_describe('metrics.token')} may only contain '
          'the characters a-z A-Z 0-9 . _ ~ + / = -');
    }
    return MetricsConfig(
      enabled: _boolean('metrics.enabled') ?? true,
      token: token,
    );
  }

  UiConfig _ui() {
    final modeName = _string('ui.mode');
    final mode = modeName == null ? null : UiMode.values.asNameMap()[modeName];
    if (modeName != null && mode == null) {
      _problems.add('${_describe('ui.mode')} must be one of spa, ssr, '
          'got ${_shown('ui.mode')}');
    }
    final configured = _string('ui.assetsDir');
    String? assetsDir;
    if (configured != null) {
      if (UiConfig.isClientDirectory(configured)) {
        assetsDir = configured;
      } else {
        _problems.add('${_describe('ui.assetsDir')} must be a directory '
            'holding index.html, got ${_shown('ui.assetsDir')}');
      }
    } else {
      assetsDir = UiConfig.defaultAssetDirs
          .where(UiConfig.isClientDirectory)
          .firstOrNull;
    }
    if (mode == UiMode.spa && assetsDir == null && configured == null) {
      _problems.add('${_describe('ui.mode')} is spa, but no web client was '
          'found in ${UiConfig.defaultAssetDirs.join(' or ')}: build it in '
          'ui/ or set ui.assetsDir');
    }
    return UiConfig(
      assetsDir: assetsDir,
      mode: mode ?? (assetsDir == null ? UiMode.ssr : UiMode.spa),
    );
  }

  /// A duration such as `10m`, or `0` when [allowZero] is true.
  Duration? _duration(String key, {required bool allowZero}) {
    final text = _string(key);
    if (text == null) return null;
    if (allowZero && text.trim() == '0') return Duration.zero;
    final parsed = parseDuration(text);
    if (parsed == null) {
      _problems.add('${_describe(key)} must be a duration such as 30s, 10m, '
          '12h or 7d${allowZero ? ', or 0' : ''}, got ${_shown(key)}');
    }
    return parsed;
  }

  UpstreamConfig _upstream() {
    final url = _httpUrl('upstream.url') ?? Uri.parse('https://pub.dev');
    final modeName = _string('upstream.mode') ?? UpstreamMode.redirect.name;
    final mode =
        UpstreamMode.values.where((m) => m.name == modeName).firstOrNull;
    if (mode == null) {
      _problems.add('${_describe('upstream.mode')} must be one of redirect, '
          'proxy, got ${_shown('upstream.mode')}');
    }
    // A proxy logs what it fetches, and credentials in the URL would go too.
    if (mode == UpstreamMode.proxy && url.userInfo.isNotEmpty) {
      _problems.add('${_describe('upstream.url')} must not contain credentials '
          'when upstream.mode is proxy');
    }
    final allowlist = _stringList('upstream.allowlist');
    final invalid = allowlist.where((name) => !isValidPackageName(name));
    if (invalid.isNotEmpty) {
      _problems.add('${_describe('upstream.allowlist')} must contain package '
          'names, got ${invalid.join(', ')}');
    }
    final archiveHosts = _stringList('upstream.allowedArchiveHosts');
    final badHosts = archiveHosts.where(
        (host) => Uri.tryParse('http://$host')?.host != host.toLowerCase());
    if (badHosts.isNotEmpty) {
      _problems.add('${_describe('upstream.allowedArchiveHosts')} must contain '
          'host names, without a scheme or port, got ${badHosts.join(', ')}');
    }
    for (final key in [
      'upstream.maxArchiveBytes',
      'upstream.maxConcurrentFetches'
    ]) {
      final value = _integer(key);
      if (value != null && value <= 0) {
        _problems.add('${_describe(key)} must be positive');
      }
    }
    return UpstreamConfig(
      url: url,
      mode: mode ?? UpstreamMode.redirect,
      cacheTtl: _duration('upstream.cacheTtl', allowZero: true) ??
          UpstreamConfig.defaultCacheTtl,
      allowlist: allowlist,
      timeout: _duration('upstream.timeout', allowZero: false) ??
          UpstreamConfig.defaultTimeout,
      allowedArchiveHosts: [for (final h in archiveHosts) h.toLowerCase()],
      requireSha256: _boolean('upstream.requireSha256') ?? true,
      allowPublishWhenUnavailable:
          _boolean('upstream.allowPublishWhenUnavailable') ?? false,
      maxArchiveBytes: _integer('upstream.maxArchiveBytes') ??
          UpstreamConfig.defaultMaxArchiveBytes,
      maxConcurrentFetches: _integer('upstream.maxConcurrentFetches') ??
          UpstreamConfig.defaultMaxConcurrentFetches,
    );
  }

  PublishConfig _publish() {
    const defaults = PublishConfig();
    final prefixes = _stringList('publish.allowedNamePrefixes');
    final badPrefixes = prefixes.where((prefix) => !isValidPackageName(prefix));
    if (badPrefixes.isNotEmpty) {
      _problems.add('${_describe('publish.allowedNamePrefixes')} must contain '
          'the start of a package name, got ${badPrefixes.join(', ')}');
    }
    final requiredFiles = _stringList('publish.requiredFiles');
    if (requiredFiles.any((file) => file.contains('/'))) {
      _problems.add('${_describe('publish.requiredFiles')} must name files at '
          'the archive root, without a directory');
    }
    final maxBytes = _integer('publish.maxArchiveBytes');
    if (maxBytes != null && maxBytes <= 0) {
      _problems.add('${_describe('publish.maxArchiveBytes')} must be positive');
    }
    final maxUnpacked = _integer('publish.maxUnpackedBytes');
    if (maxUnpacked != null && maxUnpacked <= 0) {
      _problems
          .add('${_describe('publish.maxUnpackedBytes')} must be positive');
    }
    final window = _duration('publish.retractionWindow', allowZero: true);
    final uploadTimeout = _duration('publish.uploadTimeout', allowZero: false);
    if (uploadTimeout != null && uploadTimeout >= uploadReservationTtl) {
      _problems.add('${_describe('publish.uploadTimeout')} must be shorter '
          'than the ${uploadReservationTtl.inMinutes} minutes a publish keeps '
          'its version reserved');
    }
    return PublishConfig(
      allowedNamePrefixes: prefixes,
      maxArchiveBytes: maxBytes ?? defaults.maxArchiveBytes,
      maxUnpackedBytes: maxUnpacked ?? defaults.maxUnpackedBytes,
      requiredFiles: requiredFiles,
      rejectOlderThanLatest: _boolean('publish.rejectOlderThanLatest') ?? false,
      requireVersionBump: _boolean('publish.requireVersionBump') ?? true,
      retractionWindow:
          window == Duration.zero ? null : window ?? defaults.retractionWindow,
      uploadTimeout: uploadTimeout ?? defaults.uploadTimeout,
    );
  }

  int _port() {
    final port = _integer('server.port') ?? 4000;
    if (port < 0 || port > 65535) {
      _problems.add('${_describe('server.port')} must be between 0 and 65535');
    }
    return port;
  }

  String _mongoUri() {
    const fallback = 'mongodb://localhost:27017/dart_pub';
    final uri = _string('mongo.uri') ?? fallback;
    final problem = _mongoUriProblem(uri);
    if (problem != null) {
      _problems.add('${_describe('mongo.uri')} must look like '
          'mongodb://host:27017/database: $problem');
    }
    return uri;
  }

  StorageConfig _storage() {
    final typeName = _string('storage.type') ?? StorageType.file.name;
    final type =
        StorageType.values.where((type) => type.name == typeName).firstOrNull;
    if (type == null) {
      _problems.add('${_describe('storage.type')} must be one of file, s3, '
          'got ${_shown('storage.type')}');
    }
    return StorageConfig(
      type: type ?? StorageType.file,
      file: FileStorageConfig(
        path: _string('storage.file.path') ?? 'unpub-packages',
      ),
      s3: type == StorageType.s3 ? _s3() : null,
    );
  }

  S3StorageConfig _s3() {
    final bucket = _string('storage.s3.bucket');
    if (bucket == null) {
      _problems.add('storage.s3.bucket is required when storage.type is s3');
    }

    final region = _string('storage.s3.region') ??
        _nonEmptyEnv('AWS_DEFAULT_REGION') ??
        _nonEmptyEnv('AWS_REGION');
    if (region == null) {
      _problems.add('storage.s3.region is required when storage.type is s3 '
          '(or set AWS_DEFAULT_REGION)');
    }

    final endpoint = _string('storage.s3.endpoint') ??
        _nonEmptyEnv('AWS_S3_ENDPOINT') ??
        's3.amazonaws.com';
    if (endpoint.contains('://') || endpoint.contains('/')) {
      _problems.add('${_describe('storage.s3.endpoint')} must be a host name; '
          'use storage.s3.port and storage.s3.useSSL for the rest');
    }

    final port = _integer('storage.s3.port');
    if (port != null && (port < 1 || port > 65535)) {
      _problems
          .add('${_describe('storage.s3.port')} must be between 1 and 65535');
    }

    final accessKey = _string('storage.s3.accessKey');
    final secretKey = _string('storage.s3.secretKey');
    final sessionToken = _string('storage.s3.sessionToken');
    if ((accessKey == null) != (secretKey == null)) {
      _problems.add('storage.s3.accessKey and storage.s3.secretKey '
          'must be set together');
    } else if (accessKey == null && !_hasAmbientAwsCredentials()) {
      _problems.add('S3 credentials are missing: set storage.s3.accessKey and '
          'storage.s3.secretKey, AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, '
          'or AWS_CONTAINER_CREDENTIALS_RELATIVE_URI');
    }
    if (sessionToken != null && accessKey == null) {
      _problems.add('storage.s3.sessionToken needs storage.s3.accessKey and '
          'storage.s3.secretKey; AWS_SESSION_TOKEN goes with environment keys');
    }

    return S3StorageConfig(
      bucket: bucket ?? '',
      region: region ?? '',
      endpoint: endpoint,
      port: port,
      useSSL: _boolean('storage.s3.useSSL') ?? true,
      pathStyle: _boolean('storage.s3.pathStyle'),
      accessKey: accessKey,
      secretKey: secretKey,
      sessionToken: sessionToken,
    );
  }

  String? _nonEmptyEnv(String name) {
    final value = _environment[name];
    return value == null || value.isEmpty ? null : value;
  }

  bool _hasAmbientAwsCredentials() =>
      (_nonEmptyEnv('AWS_ACCESS_KEY_ID') != null &&
          _nonEmptyEnv('AWS_SECRET_ACCESS_KEY') != null) ||
      _nonEmptyEnv('AWS_CONTAINER_CREDENTIALS_RELATIVE_URI') != null;

  AuthConfig _auth() {
    final token = _string('auth.bootstrapToken');
    if (token != null && !_bearerTokenPattern.hasMatch(token)) {
      _problems.add('${_describe('auth.bootstrapToken')} may only contain '
          'the characters a-z A-Z 0-9 . _ ~ + / = -');
    }
    final email = _string('auth.bootstrapEmail') ?? 'admin@localhost';
    if (!email.contains('@')) {
      _problems.add('${_describe('auth.bootstrapEmail')} must be an email '
          'address, got ${_shown('auth.bootstrapEmail')}');
    }
    final readAccessName = _string('auth.readAccess') ?? ReadAccess.public.name;
    final readAccess =
        ReadAccess.values.where((a) => a.name == readAccessName).firstOrNull;
    if (readAccess == null) {
      _problems.add('${_describe('auth.readAccess')} must be one of public, '
          'authenticated, got ${_shown('auth.readAccess')}');
    }
    final readTokens = _stringList('auth.readTokens');
    if (readTokens.any((t) => !_bearerTokenPattern.hasMatch(t))) {
      _problems.add('${_describe('auth.readTokens')} may only contain tokens '
          'with the characters a-z A-Z 0-9 . _ ~ + / = -');
    }
    return AuthConfig(
      bootstrapToken: token,
      bootstrapEmail: email,
      readAccess: readAccess ?? ReadAccess.public,
      readTokens: readTokens,
      admin: _adminBootstrap(),
    );
  }

  AdminBootstrapConfig? _adminBootstrap() {
    final email = _string('auth.admin.email');
    final password = _string('auth.admin.password');
    if (email == null && password == null) return null;
    if (email == null || password == null) {
      _problems.add('auth.admin.email and auth.admin.password must be set '
          'together');
      return null;
    }
    final normalized = normalizeEmail(email);
    if (!isValidEmail(normalized)) {
      _problems.add('${_describe('auth.admin.email')} must be an email '
          'address, got ${_shown('auth.admin.email')}');
    }
    final problem = passwordProblem(password);
    if (problem != null) {
      _problems.add('${_describe('auth.admin.password')} is invalid: $problem');
    }
    return AdminBootstrapConfig(email: normalized, password: password);
  }

  LoggingConfig _logging() {
    final levelName = _string('logging.level') ?? 'info';
    final level = _logLevels[levelName.toLowerCase()];
    if (level == null) {
      _problems.add('${_describe('logging.level')} must be one of '
          '${_logLevels.keys.join(', ')}, got ${_shown('logging.level')}');
    }
    final formatName = _string('logging.format') ?? LogFormat.text.name;
    final format =
        LogFormat.values.where((f) => f.name == formatName).firstOrNull;
    if (format == null) {
      _problems.add('${_describe('logging.format')} must be one of text, json, '
          'got ${_shown('logging.format')}');
    }
    return LoggingConfig(
      level: level ?? Level.INFO,
      format: format ?? LogFormat.text,
    );
  }
}
