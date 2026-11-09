import 'dart:io';

import 'package:logging/logging.dart';
import 'package:yaml/yaml.dart';

import '../logging.dart';

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
  'auth.bootstrapToken': _ValueKind.string,
  'auth.bootstrapEmail': _ValueKind.string,
  'auth.readAccess': _ValueKind.string,
  'auth.readTokens': _ValueKind.stringList,
  'logging.level': _ValueKind.string,
  'logging.format': _ValueKind.string,
};

/// Keys whose values must never appear in messages.
const _secretKeys = {
  'storage.s3.accessKey',
  'storage.s3.secretKey',
  'storage.s3.sessionToken',
  'auth.bootstrapToken',
  'auth.readTokens',
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

  const ServerConfig({
    required this.host,
    required this.port,
    required this.publicUrl,
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

class UpstreamConfig {
  final Uri url;

  const UpstreamConfig({required this.url});
}

/// Who may read packages.
enum ReadAccess { public, authenticated }

class AuthConfig {
  /// Bearer token that may publish. Publishing is disabled when null.
  final String? bootstrapToken;

  /// Uploader email recorded for publishes using [bootstrapToken].
  final String bootstrapEmail;

  final ReadAccess readAccess;

  /// Bearer tokens that may read when [readAccess] is `authenticated`, in
  /// addition to [bootstrapToken]. They cannot publish.
  final List<String> readTokens;

  const AuthConfig({
    required this.bootstrapToken,
    required this.bootstrapEmail,
    this.readAccess = ReadAccess.public,
    this.readTokens = const [],
  });
}

class LoggingConfig {
  final Level level;
  final LogFormat format;

  const LoggingConfig({required this.level, required this.format});
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
  final AuthConfig auth;
  final LoggingConfig logging;

  const Config({
    required this.server,
    required this.mongo,
    required this.storage,
    required this.upstream,
    required this.auth,
    required this.logging,
  });

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
      }
    }
  }

  void addOverride(String key, String? value, String source) {
    if (value == null) return;
    _values[key] = value;
    _sources[key] = source;
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
    );
    final mongo = MongoConfig(uri: _mongoUri());
    final storage = _storage();
    final upstream = UpstreamConfig(
      url: _httpUrl('upstream.url') ?? Uri.parse('https://pub.dev'),
    );
    final auth = _auth();
    final logging = _logging();
    if (_problems.isNotEmpty) throw ConfigException(_problems);
    return Config(
      server: server,
      mongo: mongo,
      storage: storage,
      upstream: upstream,
      auth: auth,
      logging: logging,
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
    if (readAccess == ReadAccess.authenticated &&
        readTokens.isEmpty &&
        token == null) {
      _problems.add('auth.readAccess is authenticated, so at least one of '
          'auth.readTokens and auth.bootstrapToken must be set');
    }
    return AuthConfig(
      bootstrapToken: token,
      bootstrapEmail: email,
      readAccess: readAccess ?? ReadAccess.public,
      readTokens: readTokens,
    );
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
