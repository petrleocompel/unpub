import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';
import 'package:unpub/unpub.dart';
import 'package:yaml/yaml.dart';

const s3Yaml = '''
storage:
  type: s3
  s3:
    bucket: packages
    region: eu-west-1
    accessKey: key
    secretKey: secret
''';

Config parse(String? yaml, {Map<String, String> env = const {}}) =>
    Config.parse(yaml, environment: env);

Matcher problemsContaining(List<Object> matchers) =>
    throwsA(isA<ConfigException>()
        .having((e) => e.problems, 'problems', containsAll(matchers)));

void main() {
  group('admin bootstrap', () {
    test('is absent by default', () {
      expect(parse(null).auth.admin, isNull);
    });

    test('reads the file and normalizes the email', () {
      var admin = parse('auth:\n  admin:\n    email: Root@Example.com\n'
              '    password: long-enough\n')
          .auth
          .admin!;
      expect(admin.email, 'root@example.com');
      expect(admin.password, 'long-enough');
    });

    test('reads the environment', () {
      var admin = parse(null, env: {
        'UNPUB_AUTH_ADMIN_EMAIL': 'root@example.com',
        'UNPUB_AUTH_ADMIN_PASSWORD': 'long-enough',
      }).auth.admin!;
      expect(admin.email, 'root@example.com');
    });

    test('needs both values', () {
      expect(() => parse(null, env: {'UNPUB_AUTH_ADMIN_EMAIL': 'a@b.c'}),
          problemsContaining([contains('must be set together')]));
      expect(
          () => parse(null, env: {'UNPUB_AUTH_ADMIN_PASSWORD': 'long-enough'}),
          problemsContaining([contains('must be set together')]));
    });

    test('rejects a bad email and a short password without printing it', () {
      try {
        parse('auth:\n  admin:\n    email: nobody\n    password: hunter\n');
        fail('expected a ConfigException');
      } on ConfigException catch (error) {
        expect(error.toString(), contains('auth.admin.email'));
        expect(error.toString(), contains('at least 8'));
        expect(error.toString(), isNot(contains('hunter')));
      }
    });
  });

  group('forwarded address', () {
    test('is not trusted by default', () {
      expect(parse(null).server.trustForwardedFor, isFalse);
    });

    test('can be enabled', () {
      expect(
          parse('server:\n  trustForwardedFor: true\n')
              .server
              .trustForwardedFor,
          isTrue);
      expect(
          parse(null, env: {'UNPUB_SERVER_TRUST_FORWARDED_FOR': 'true'})
              .server
              .trustForwardedFor,
          isTrue);
    });
  });

  group('defaults', () {
    test('apply without a file', () {
      var config = parse(null);
      expect(config.server.host, '0.0.0.0');
      expect(config.server.port, 4000);
      expect(config.server.publicUrl, isNull);
      expect(config.mongo.uri, 'mongodb://localhost:27017/dart_pub');
      expect(config.storage.type, StorageType.file);
      expect(config.storage.file.path, 'unpub-packages');
      expect(config.upstream.url.toString(), 'https://pub.dev');
      expect(config.auth.bootstrapToken, isNull);
      expect(config.auth.bootstrapEmail, 'admin@localhost');
      expect(config.auth.readAccess, ReadAccess.public);
      expect(config.auth.readTokens, isEmpty);
      expect(config.logging.level, Level.INFO);
      expect(config.logging.format, LogFormat.text);
    });

    test('apply to empty sections', () {
      expect(parse('server:\nauth:\n').server.port, 4000);
    });
  });

  test('reads every section from yaml', () {
    var config = parse('''
server:
  host: 127.0.0.1
  port: 5000
  publicUrl: https://pub.example.com
mongo:
  uri: mongodb://db:27017/pub
storage:
  type: file
  file:
    path: /data/packages
upstream:
  url: https://mirror.example.com
auth:
  bootstrapToken: abc.DEF-123
  bootstrapEmail: ops@example.com
logging:
  level: debug
  format: json
''');
    expect(config.server.host, '127.0.0.1');
    expect(config.server.port, 5000);
    expect(config.server.publicUrl.toString(), 'https://pub.example.com');
    expect(config.mongo.uri, 'mongodb://db:27017/pub');
    expect(config.storage.file.path, '/data/packages');
    expect(config.upstream.url.toString(), 'https://mirror.example.com');
    expect(config.auth.bootstrapToken, 'abc.DEF-123');
    expect(config.auth.bootstrapEmail, 'ops@example.com');
    expect(config.logging.level, Level.FINE);
    expect(config.logging.format, LogFormat.json);
  });

  group('precedence', () {
    test('environment overrides yaml', () {
      var config =
          parse('server:\n  port: 5000\nmongo:\n  uri: mongodb://a/b\n', env: {
        'UNPUB_SERVER_PORT': '6000',
        'UNPUB_MONGO_URI': 'mongodb://env/db',
      });
      expect(config.server.port, 6000);
      expect(config.mongo.uri, 'mongodb://env/db');
    });

    test('cli flags override the environment', () {
      var config = Config.parse(null,
          environment: {'UNPUB_SERVER_PORT': '6000', 'UNPUB_SERVER_HOST': 'a'},
          host: 'localhost',
          port: '7000');
      expect(config.server.host, 'localhost');
      expect(config.server.port, 7000);
    });

    test('camelCase keys accept both spellings', () {
      for (var name in [
        'UNPUB_AUTH_BOOTSTRAP_TOKEN',
        'UNPUB_AUTH_BOOTSTRAPTOKEN'
      ]) {
        expect(parse(null, env: {name: 'tok'}).auth.bootstrapToken, 'tok');
      }
    });

    test('nested keys are reachable', () {
      var config = parse(null, env: {
        'UNPUB_STORAGE_TYPE': 's3',
        'UNPUB_STORAGE_S3_BUCKET': 'b',
        'UNPUB_STORAGE_S3_REGION': 'r',
        'UNPUB_STORAGE_S3_ACCESS_KEY': 'k',
        'UNPUB_STORAGE_S3_SECRET_KEY': 's',
        'UNPUB_STORAGE_S3_USE_SSL': 'false',
        'UNPUB_STORAGE_S3_PORT': '9000',
      });
      expect(config.storage.s3!.bucket, 'b');
      expect(config.storage.s3!.useSSL, isFalse);
      expect(config.storage.s3!.port, 9000);
    });

    test('empty variables count as unset', () {
      expect(
          parse(null, env: {'UNPUB_AUTH_BOOTSTRAP_TOKEN': ''})
              .auth
              .bootstrapToken,
          isNull);
    });

    test('unrelated UNPUB_ variables are ignored', () {
      expect(parse(null, env: {'UNPUB_SERVICE_HOST': '10.0.0.1'}).server.port,
          4000);
    });
  });

  group('validation', () {
    test('reports every problem at once', () {
      expect(
        () => parse('''
server:
  port: not-a-number
  publicUrl: ftp://x
mongo:
  uri: postgres://db
storage:
  type: tape
upstream:
  url: nope
auth:
  bootstrapToken: "has spaces"
  bootstrapEmail: nobody
logging:
  level: loud
  format: xml
'''),
        problemsContaining([
          contains('server.port'),
          contains('server.publicUrl'),
          contains('mongo.uri'),
          contains('storage.type'),
          contains('upstream.url'),
          contains('auth.bootstrapToken'),
          contains('auth.bootstrapEmail'),
          contains('logging.level'),
          contains('logging.format'),
        ]),
      );
    });

    test('reports where a bad value came from', () {
      expect(() => parse(null, env: {'UNPUB_SERVER_PORT': 'x'}),
          problemsContaining([contains('UNPUB_SERVER_PORT')]));
    });

    test('rejects unknown keys', () {
      expect(() => parse('server:\n  prot: 1\ncache:\n  size: 1\n'),
          problemsContaining([contains('server.prot'), contains('cache')]));
    });

    test('rejects an out of range port', () {
      expect(() => parse('server:\n  port: 70000\n'),
          problemsContaining([contains('between 0 and 65535')]));
    });

    test('public url must be an origin', () {
      expect(() => parse('server:\n  publicUrl: https://x.example.com/pub\n'),
          problemsContaining([contains('without a path')]));
      expect(
          parse('server:\n  publicUrl: https://x.example.com/\n')
              .server
              .publicUrl,
          isNotNull);
    });

    group('mongo uri', () {
      for (var uri in [
        'mongodb://localhost/db',
        'mongodb://user:p%40ss@localhost:27017/db',
        'mongodb://a:27017,b:27018/db?replicaSet=rs0',
        'mongodb://user:pw@a,b:27018/db',
        'mongodb://[::1]:27017/db',
        'mongodb+srv://user:pw@cluster.example.com/db?tls=true',
      ]) {
        test('accepts $uri', () {
          expect(parse('mongo:\n  uri: "$uri"\n').mongo.uri, uri);
        });
      }

      const secret = 'hunter2secret';
      for (var uri in [
        'mongodb://user:$secret@localhost:bad/db',
        'mongodb://user:$secret@localhost:99999/db',
        'mongodb://user:$secret@a:1,b:bad/db',
        'mongodb://user:$secret@:27017/db',
        'mongodb://user:$secret:more@localhost/db',
        'mongodb://user:pa/$secret@localhost/db',
        'mongodb://user:pa$secret@b@localhost/db',
        'mongodb://user:$secret@localhost',
        'mongodb://user:$secret@localhost/',
        'mongodb://user:se cret$secret@localhost/db',
        'mongodb+srv://user:$secret@a,b/db',
        'mongodb+srv://user:$secret@a:27017/db',
        'postgres://user:$secret@localhost/db',
        secret,
      ]) {
        test('rejects $uri without quoting it', () {
          try {
            parse('mongo:\n  uri: "$uri"\n');
            fail('expected a ConfigException');
          } on ConfigException catch (error) {
            expect(error.toString(), contains('mongo.uri'));
            expect(error.toString(), isNot(contains(secret)));
          }
        });
      }
    });

    test('mongo uri needs a database', () {
      expect(() => parse('mongo:\n  uri: mongodb://db:27017\n'),
          problemsContaining([contains('database name')]));
    });

    test('reports yaml syntax errors with a line number', () {
      expect(() => parse('server:\n  port: [\n'),
          problemsContaining([contains('line')]));
    });

    test('rejects a non-mapping document', () {
      expect(
          () => parse('- a\n'), problemsContaining([contains('YAML mapping')]));
    });

    test('never prints secrets', () {
      try {
        parse('auth:\n  bootstrapToken: "se cret"\n'
            'mongo:\n  uri: "postgres://user:hunter2@db"\n');
        fail('expected a ConfigException');
      } on ConfigException catch (error) {
        expect(error.toString(), isNot(contains('se cret')));
        expect(error.toString(), isNot(contains('hunter2')));
      }
    });
  });

  group('documented environment variables', () {
    final repository = path.dirname(Directory.current.path);
    final compose = loadYaml(
        File(path.join(repository, 'docker-compose.yml')).readAsStringSync());
    final environment = (compose['services']['unpub']['environment'] as YamlMap)
        .cast<String, String>();

    test('compose passes each variable through under its own name', () {
      for (var entry in environment.entries) {
        var reference = RegExp(r'^\$\{(\w+)').firstMatch(entry.value);
        if (reference != null) expect(reference.group(1), entry.key);
      }
    });

    test('compose values reach the config', () {
      var config = parse(null, env: {
        'UNPUB_SERVER_PUBLIC_URL': 'https://pub.example.com',
        'UNPUB_AUTH_BOOTSTRAP_TOKEN': 'token',
        'UNPUB_AUTH_BOOTSTRAP_EMAIL': 'ops@example.com',
        'UNPUB_AUTH_READ_ACCESS': 'authenticated',
        'UNPUB_AUTH_READ_TOKENS': 'reader',
      });
      expect(
          environment.keys,
          containsAll([
            'UNPUB_SERVER_PUBLIC_URL',
            'UNPUB_AUTH_BOOTSTRAP_TOKEN',
            'UNPUB_AUTH_BOOTSTRAP_EMAIL',
            'UNPUB_AUTH_READ_ACCESS',
            'UNPUB_AUTH_READ_TOKENS',
          ]));
      expect(config.server.publicUrl.toString(), 'https://pub.example.com');
      expect(config.auth.bootstrapToken, 'token');
      expect(config.auth.bootstrapEmail, 'ops@example.com');
      expect(config.auth.readTokens, ['reader']);
    });

    for (var file in ['docker-compose.yml', 'README.md']) {
      test('$file uses only canonical names', () {
        var text = File(path.join(repository, file)).readAsStringSync();
        expect(text, isNot(matches(RegExp(r'UNPUB_(BOOTSTRAP|PUBLIC)_'))));
      });
    }
  });

  group('read access', () {
    test('reads tokens from a yaml list', () {
      var auth = parse('auth:\n  readAccess: authenticated\n'
              '  readTokens:\n    - one\n    - two\n')
          .auth;
      expect(auth.readAccess, ReadAccess.authenticated);
      expect(auth.readTokens, ['one', 'two']);
    });

    test('reads comma separated tokens from the environment', () {
      var auth = parse(null, env: {
        'UNPUB_AUTH_READ_ACCESS': 'authenticated',
        'UNPUB_AUTH_READ_TOKENS': 'one, two,,three ',
      }).auth;
      expect(auth.readAccess, ReadAccess.authenticated);
      expect(auth.readTokens, ['one', 'two', 'three']);
    });

    test('rejects an unknown mode', () {
      expect(() => parse('auth:\n  readAccess: private\n'),
          problemsContaining([contains('auth.readAccess')]));
    });

    test('authenticated needs no static token, users can exist', () {
      var auth = parse('auth:\n  readAccess: authenticated\n').auth;
      expect(auth.readAccess, ReadAccess.authenticated);
      expect(auth.readTokens, isEmpty);
    });

    test('rejects invalid tokens without printing them', () {
      try {
        parse('auth:\n  readTokens:\n    - "se cret"\n');
        fail('expected a ConfigException');
      } on ConfigException catch (error) {
        expect(error.toString(), contains('auth.readTokens'));
        expect(error.toString(), isNot(contains('se cret')));
      }
    });

    test('rejects a value that is not a list of strings', () {
      expect(() => parse('auth:\n  readTokens:\n    - 123\n'),
          problemsContaining([contains('list of strings')]));
    });
  });

  group('s3', () {
    test('accepts a complete section', () {
      var s3 = parse(s3Yaml).storage.s3!;
      expect(s3.bucket, 'packages');
      expect(s3.region, 'eu-west-1');
      expect(s3.endpoint, 's3.amazonaws.com');
      expect(s3.useSSL, isTrue);
    });

    test('a session token needs explicit keys', () {
      expect(
          () => parse(
                  'storage:\n  type: s3\n  s3:\n    bucket: x\n    region: y\n'
                  '    sessionToken: z\n',
                  env: {
                    'AWS_ACCESS_KEY_ID': 'a',
                    'AWS_SECRET_ACCESS_KEY': 'b',
                  }),
          problemsContaining([contains('sessionToken')]));
    });

    test('is ignored unless selected', () {
      expect(parse('storage:\n  s3:\n    bucket: x\n').storage.s3, isNull);
    });

    test('requires bucket, region and credentials', () {
      expect(
        () => parse('storage:\n  type: s3\n'),
        problemsContaining([
          contains('storage.s3.bucket'),
          contains('storage.s3.region'),
          contains('credentials'),
        ]),
      );
    });

    test('falls back to AWS variables', () {
      var s3 = parse('storage:\n  type: s3\n  s3:\n    bucket: b\n', env: {
        'AWS_DEFAULT_REGION': 'us-west-2',
        'AWS_ACCESS_KEY_ID': 'k',
        'AWS_SECRET_ACCESS_KEY': 's',
        'AWS_S3_ENDPOINT': 'minio.internal',
      }).storage.s3!;
      expect(s3.region, 'us-west-2');
      expect(s3.endpoint, 'minio.internal');
      expect(s3.accessKey, isNull);
    });

    test('accepts ecs container credentials', () {
      var yaml = 'storage:\n  type: s3\n  s3:\n    bucket: b\n    region: r\n';
      expect(
          parse(yaml, env: {'AWS_CONTAINER_CREDENTIALS_RELATIVE_URI': '/x'})
              .storage
              .s3,
          isNotNull);
    });

    test('access key and secret must come together', () {
      expect(
        () => parse('storage:\n  type: s3\n  s3:\n'
            '    bucket: b\n    region: r\n    accessKey: k\n'),
        problemsContaining([contains('set together')]),
      );
    });

    test('endpoint must be a host name', () {
      expect(
        () => parse('$s3Yaml    endpoint: https://minio.example.com\n'),
        problemsContaining([contains('must be a host name')]),
      );
    });
  });

  group('publish', () {
    test('has the documented defaults', () {
      final publish = parse(null).publish;
      expect(publish.allowedNamePrefixes, isEmpty);
      expect(publish.maxArchiveBytes, 100 * 1024 * 1024);
      expect(publish.requiredFiles, isEmpty);
      expect(publish.rejectOlderThanLatest, isFalse);
      expect(publish.requireVersionBump, isTrue);
      expect(publish.retractionWindow, const Duration(days: 7));
    });

    test('reads the file', () {
      final publish = parse('''
publish:
  allowedNamePrefixes: [acme_, corp_]
  maxArchiveBytes: 1024
  requiredFiles: [README.md, LICENSE]
  rejectOlderThanLatest: true
  requireVersionBump: false
  retractionWindow: 30d
''').publish;
      expect(publish.allowedNamePrefixes, ['acme_', 'corp_']);
      expect(publish.maxArchiveBytes, 1024);
      expect(publish.requiredFiles, ['README.md', 'LICENSE']);
      expect(publish.rejectOlderThanLatest, isTrue);
      expect(publish.requireVersionBump, isFalse);
      expect(publish.retractionWindow, const Duration(days: 30));
    });

    test('reads the environment', () {
      final publish = parse(null, env: {
        'UNPUB_PUBLISH_ALLOWED_NAME_PREFIXES': 'acme_,corp_',
        'UNPUB_PUBLISH_MAX_ARCHIVE_BYTES': '2048',
        'UNPUB_PUBLISH_RETRACTION_WINDOW': '12h',
      }).publish;
      expect(publish.allowedNamePrefixes, ['acme_', 'corp_']);
      expect(publish.maxArchiveBytes, 2048);
      expect(publish.retractionWindow, const Duration(hours: 12));
    });

    for (final zero in ['0', '"0"']) {
      test('a retraction window of $zero means unlimited', () {
        expect(
            parse('publish:\n  retractionWindow: $zero\n')
                .publish
                .retractionWindow,
            isNull);
      });
    }

    final invalid = {
      'publish:\n  retractionWindow: soon\n': 'publish.retractionWindow',
      'publish:\n  maxArchiveBytes: 0\n': 'publish.maxArchiveBytes',
      'publish:\n  allowedNamePrefixes: [Bad-Prefix]\n':
          'publish.allowedNamePrefixes',
      'publish:\n  requiredFiles: [doc/README.md]\n': 'publish.requiredFiles',
      'publish:\n  unknown: 1\n': 'unknown key',
    };
    invalid.forEach((yaml, message) {
      test('rejects ${yaml.replaceAll('\n', ' ')}', () {
        expect(() => parse(yaml), problemsContaining([contains(message)]));
      });
    });
  });

  group('upstream', () {
    test('has the documented defaults', () {
      final upstream = parse(null).upstream;
      expect(upstream.url, Uri.parse('https://pub.dev'));
      expect(upstream.mode, UpstreamMode.redirect);
      expect(upstream.cacheTtl, const Duration(minutes: 10));
      expect(upstream.allowlist, isEmpty);
      expect(upstream.timeout, const Duration(seconds: 30));
    });

    test('reads the file', () {
      final upstream = parse('''
upstream:
  url: https://mirror.example.com
  mode: proxy
  cacheTtl: 1h
  allowlist: [http, path]
  timeout: 5s
''').upstream;
      expect(upstream.mode, UpstreamMode.proxy);
      expect(upstream.cacheTtl, const Duration(hours: 1));
      expect(upstream.allowlist, ['http', 'path']);
      expect(upstream.timeout, const Duration(seconds: 5));
    });

    test('reads the environment', () {
      final upstream = parse(null, env: {
        'UNPUB_UPSTREAM_MODE': 'proxy',
        'UNPUB_UPSTREAM_CACHE_TTL': '30s',
        'UNPUB_UPSTREAM_ALLOWLIST': 'http,path',
      }).upstream;
      expect(upstream.mode, UpstreamMode.proxy);
      expect(upstream.cacheTtl, const Duration(seconds: 30));
      expect(upstream.allowlist, ['http', 'path']);
    });

    test('archive hosts are normalized to lowercase', () {
      final hosts = parse(
              'upstream:\n  allowedArchiveHosts: [CDN.Example.com, b.example]\n')
          .upstream
          .allowedArchiveHosts;
      expect(hosts, ['cdn.example.com', 'b.example']);
      expect(parse(null).upstream.allowedArchiveHosts, isEmpty);
    });

    test('the limits on archives have defaults and can be set', () {
      expect(parse(null).upstream.maxArchiveBytes, 256 * 1024 * 1024);
      expect(parse(null).upstream.maxConcurrentFetches, 4);
      final upstream = parse(
              'upstream:\n  maxArchiveBytes: 1024\n  maxConcurrentFetches: 2\n')
          .upstream;
      expect(upstream.maxArchiveBytes, 1024);
      expect(upstream.maxConcurrentFetches, 2);
    });

    test('publishing during an outage is off unless turned on', () {
      expect(parse(null).upstream.allowPublishWhenUnavailable, isFalse);
      expect(
          parse('upstream:\n  allowPublishWhenUnavailable: true\n')
              .upstream
              .allowPublishWhenUnavailable,
          isTrue);
    });

    test('requireSha256 is on unless turned off', () {
      expect(parse(null).upstream.requireSha256, isTrue);
      expect(
          parse('upstream:\n  requireSha256: false\n').upstream.requireSha256,
          isFalse);
      expect(
          parse(null, env: {'UNPUB_UPSTREAM_REQUIRE_SHA256': 'false'})
              .upstream
              .requireSha256,
          isFalse);
    });

    test('a cache TTL of 0 always asks the upstream', () {
      expect(
          parse('upstream:\n  cacheTtl: 0\n').upstream.cacheTtl, Duration.zero);
    });

    final invalid = {
      'upstream:\n  mode: mirror\n': 'upstream.mode',
      'upstream:\n  cacheTtl: later\n': 'upstream.cacheTtl',
      'upstream:\n  timeout: 0\n': 'upstream.timeout',
      'upstream:\n  allowlist: [Not-A-Package]\n': 'upstream.allowlist',
      'publish:\n  maxUnpackedBytes: 0\n': 'publish.maxUnpackedBytes',
      'upstream:\n  maxArchiveBytes: 0\n': 'upstream.maxArchiveBytes',
      'upstream:\n  maxConcurrentFetches: 0\n': 'upstream.maxConcurrentFetches',
      'upstream:\n  allowedArchiveHosts: [https://cdn.example.com]\n':
          'upstream.allowedArchiveHosts',
      'upstream:\n  allowedArchiveHosts: [cdn.example.com:8443]\n':
          'upstream.allowedArchiveHosts',
      'upstream:\n  mode: proxy\n  url: https://u:p@example.com\n':
          'must not contain credentials',
    };
    invalid.forEach((yaml, message) {
      test('rejects ${yaml.replaceAll('\n', ' ')}', () {
        expect(() => parse(yaml), problemsContaining([contains(message)]));
      });
    });

    test('does not repeat upstream credentials in the message', () {
      try {
        parse('upstream:\n  mode: proxy\n  url: https://u:hunter2@e.com\n');
        fail('should have thrown');
      } on ConfigException catch (error) {
        expect('$error', isNot(contains('hunter2')));
      }
    });
  });

  group('load', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('unpub-config-');
    });

    tearDown(() async {
      await directory.delete(recursive: true);
    });

    test('reads the given file', () async {
      var file = File(path.join(directory.path, 'custom.yaml'));
      await file.writeAsString('server:\n  port: 5555\n');
      expect(Config.load(path: file.path, environment: {}).server.port, 5555);
    });

    test('an explicit missing file is an error', () {
      expect(
        () => Config.load(
            path: path.join(directory.path, 'nope.yaml'), environment: {}),
        problemsContaining([contains('not found')]),
      );
    });

    test('the example config is valid', () {
      expect(
        Config.load(path: '../unpub.example.yaml', environment: {}).server.port,
        4000,
      );
    });
  });
}
