import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:mongo_dart/mongo_dart.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';
import 'package:unpub/unpub.dart' as unpub;

final notExistingPacakge = 'not_existing_package';
final baseDir = path.absolute('unpub-packages');
final pubHostedUrl = 'http://localhost:4000';
final baseUri = Uri.parse(pubHostedUrl);

final testMongoUri = Platform.environment['UNPUB_TEST_MONGO_URI'] ??
    'mongodb://localhost:27017/dart_pub_test';

final package0 = 'package_0';
final package1 = 'package_1';
final email0 = 'email0@example.com';
final email1 = 'email1@example.com';
final email2 = 'email2@example.com';
final email3 = 'email3@example.com';

/// The token the pub client presents in tests.
const testToken = 'test-bootstrap-token';

/// A server which accepts [token] and records [opEmail] as the operator.
Future<HttpServer> createServer(
  String opEmail, {
  String? token = testToken,
  Set<String>? readTokens,
}) async {
  final db = Db(testMongoUri);
  await db.open();
  addTearDown(db.close);
  await Directory(baseDir).create(recursive: true);

  final app = unpub.App(
    metaStore: unpub.MongoStore(db),
    packageStore: unpub.FileStore(baseDir),
    authenticator: unpub.BootstrapTokenAuthenticator(
      token: token,
      email: opEmail,
    ),
    readAuthenticator:
        readTokens == null ? null : unpub.ReadTokenAuthenticator(readTokens),
  );

  return app.serve('0.0.0.0', 4000);
}

late Directory _pubHome;
late Map<String, String> _pubEnvironment;

/// Gives the pub client an isolated home that holds [testToken].
///
/// Keeps tests away from the credentials of whoever runs them. pub reads its
/// config from `$HOME` on macOS and from `$XDG_CONFIG_HOME` on Linux.
Future<void> setUpPubClient() async {
  _pubHome = await Directory.systemTemp.createTemp('unpub-test-pub-');
  _pubEnvironment = {
    'HOME': _pubHome.path,
    'XDG_CONFIG_HOME': path.join(_pubHome.path, 'config'),
    'PUB_CACHE': path.join(_pubHome.path, 'cache'),
    'PUB_HOSTED_URL': pubHostedUrl,
  };
  await addPubToken();
}

/// Stores [testToken] in the pub client, which forgets a token after a 401.
Future<void> addPubToken() async {
  final process = await Process.start(
    'dart',
    ['pub', 'token', 'add', pubHostedUrl],
    environment: _pubEnvironment,
  );
  process.stdin.writeln(testToken);
  await process.stdin.close();
  final out = process.stdout.transform(utf8.decoder).join();
  final err = process.stderr.transform(utf8.decoder).join();
  final code = await process.exitCode;
  if (code != 0) {
    throw StateError('dart pub token add failed: ${await out}${await err}');
  }
}

Future<void> tearDownPubClient() => _pubHome.delete(recursive: true);

Future<http.Response> getVersions(String package) {
  package = Uri.encodeComponent(package);
  return http.get(baseUri.resolve('/api/packages/$package'));
}

Future<http.Response> getSpecificVersion(String package, String version) {
  package = Uri.encodeComponent(package);
  version = Uri.encodeComponent(version);
  return http.get(baseUri.resolve('/api/packages/$package/versions/$version'));
}

Future<ProcessResult> pubPublish(String name, String version) {
  return Process.run('dart', ['pub', 'publish', '--force'],
      workingDirectory: path.absolute('test/fixtures', name, version),
      environment: _pubEnvironment);
}

/// Runs `dart pub get` in a throwaway package depending on [name] [version].
Future<ProcessResult> pubGetConsumer(String name, String version) async {
  final directory = await _pubHome.createTemp('consumer-');
  await File(path.join(directory.path, 'pubspec.yaml')).writeAsString('''
name: consumer
environment:
  sdk: ^3.5.0
dependencies:
  $name: $version
''');
  return Process.run('dart', ['pub', 'get'],
      workingDirectory: directory.path, environment: _pubEnvironment);
}

const _authorized = {HttpHeaders.authorizationHeader: 'Bearer $testToken'};

// `dart pub uploader` no longer talks to servers, so these use the API directly.
Future<http.Response> addUploader(String name, String email) {
  return http.post(
    baseUri.resolve('/api/packages/$name/uploaders'),
    headers: _authorized,
    body: 'email=${Uri.encodeQueryComponent(email)}',
  );
}

Future<http.Response> removeUploader(String name, String email) {
  return http.delete(
    baseUri
        .resolve('/api/packages/$name/uploaders/${Uri.encodeComponent(email)}'),
    headers: _authorized,
  );
}
