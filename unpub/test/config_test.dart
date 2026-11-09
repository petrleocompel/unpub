import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';
import 'package:unpub/unpub.dart';

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

  group('s3', () {
    test('accepts a complete section', () {
      var s3 = parse(s3Yaml).storage.s3!;
      expect(s3.bucket, 'packages');
      expect(s3.region, 'eu-west-1');
      expect(s3.endpoint, 's3.amazonaws.com');
      expect(s3.useSSL, isTrue);
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
