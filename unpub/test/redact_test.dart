import 'package:logging/logging.dart';
import 'package:test/test.dart';
import 'package:unpub/unpub.dart';

void main() {
  group('redactUri', () {
    const cases = {
      'mongodb://db:27017/pub': 'mongodb://db:27017/pub',
      'mongodb://user:secret@db:27017/pub': 'mongodb://***@db:27017/pub',
      'mongodb://user:secret@a:1,b:2/pub': 'mongodb://***@a:1,b:2/pub',
      'mongodb+srv://user:secret@db/pub': 'mongodb+srv://***@db/pub',
      'mongodb://user:se@cret@db/pub': 'mongodb://***@db/pub',
      'mongodb://user:se/cret@db/pub': 'mongodb://***@db/pub',
      'mongodb://user:se?cret@db/pub': 'mongodb://***@db/pub',
      'mongodb://db/pub?tlsCertificateKeyFilePassword=secret':
          'mongodb://db/pub?***',
      'user:secret@db/pub': '***@db/pub',
    };
    cases.forEach((uri, expected) {
      test(uri, () => expect(redactUri(uri), expected));
    });
  });

  test('redactConnectionStrings handles text around the uri', () {
    expect(
      redactConnectionStrings(
          'FormatException: Invalid port (at character 28)\n'
          'mongodb://user:secret@localhost:bad/db\n'
          '                           ^\n'),
      allOf(isNot(contains('secret')),
          contains('mongodb://***@localhost:bad/db')),
    );
    expect(redactConnectionStrings('Invalid: mongodb://u:p:q@h/d.userInfo x'),
        'Invalid: mongodb://***@h/d.userInfo x');
    expect(redactConnectionStrings('no uri here'), 'no uri here');
  });

  test('UnpubServer.start does not quote the connection string', () async {
    final config = Config(
      server: const ServerConfig(host: '127.0.0.1', port: 0, publicUrl: null),
      // Built directly because Config.parse rejects it, so the driver sees it
      // and fails with a FormatException that repeats the whole URI.
      mongo: const MongoConfig(uri: 'mongodb://user:secret@localhost:bad/db'),
      storage: const StorageConfig(
          type: StorageType.file,
          file: FileStorageConfig(path: 'unused'),
          s3: null),
      upstream: UpstreamConfig(url: Uri.parse('https://pub.dev')),
      auth: const AuthConfig(bootstrapToken: null, bootstrapEmail: 'a@b.c'),
      logging: const LoggingConfig(level: Level.OFF, format: LogFormat.text),
    );
    await expectLater(
      UnpubServer.start(config),
      throwsA(isA<RedactedException>()
          .having((e) => e.message, 'message', isNot(contains('secret')))),
    );
  });
}
