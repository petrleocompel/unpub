import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:mongo_dart/mongo_dart.dart';
import 'package:path/path.dart' as path;
import 'package:shelf/shelf.dart' as shelf;
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

/// Accepts one Bearer token as a fixed identity, a publisher by default.
class FakeAuthenticator implements unpub.Authenticator {
  final String? token;
  final String email;
  final unpub.Role role;

  const FakeAuthenticator(
    this.token,
    this.email, {
    this.role = unpub.Role.publisher,
  });

  @override
  Future<unpub.Principal?> authenticate(shelf.Request request) async {
    if (token == null || unpub.bearerToken(request) != token) return null;
    return unpub.Principal(email, role: role);
  }
}

/// A server where [token] authenticates the publisher [opEmail].
Future<HttpServer> createServer(
  String opEmail, {
  String? token = testToken,
  bool authenticatedReads = false,
  unpub.Role role = unpub.Role.publisher,
  unpub.PublishConfig publish = const unpub.PublishConfig(),
  Future<void> Function(Map<String, dynamic>, String)? uploadValidator,
}) async {
  final db = Db(testMongoUri);
  await db.open();
  addTearDown(db.close);
  await Directory(baseDir).create(recursive: true);

  final app = unpub.App(
    metaStore: unpub.MongoStore(db),
    packageStore: unpub.FileStore(baseDir),
    authenticator: FakeAuthenticator(token, opEmail, role: role),
    readAccess: authenticatedReads
        ? unpub.ReadAccess.authenticated
        : unpub.ReadAccess.public,
    publishPolicy: unpub.PublishPolicy(publish),
    uploadValidator: uploadValidator,
  );

  return app.serve('0.0.0.0', 4000);
}

/// A `dart pub publish` upload of an archive holding [pubspec].
shelf.Request uploadRequest(String pubspec, Map<String, String> headers) {
  const boundary = 'test-boundary';
  final archive = Archive()
    ..addFile(ArchiveFile.string('pubspec.yaml', pubspec));
  final tarball = GZipEncoder().encodeBytes(TarEncoder().encodeBytes(archive));
  return shelf.Request(
    'POST',
    Uri.parse('http://internal:4000/api/packages/versions/newUpload'),
    headers: {
      ...headers,
      'content-type': 'multipart/form-data; boundary=$boundary',
    },
    body: [
      ...utf8.encode('--$boundary\r\n'
          'content-disposition: form-data; name="file"; filename="p.tar.gz"\r\n'
          'content-type: application/octet-stream\r\n\r\n'),
      ...tarball,
      ...utf8.encode('\r\n--$boundary--\r\n'),
    ],
  );
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

/// Stores [token] in the pub client, which forgets a token after a 401.
Future<void> addPubToken([String token = testToken]) async {
  final process = await Process.start(
    'dart',
    ['pub', 'token', 'add', pubHostedUrl],
    environment: _pubEnvironment,
  );
  process.stdin.writeln(token);
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

/// Publishes a generated package holding [files], and a LICENSE because pub
/// refuses to publish without one.
Future<ProcessResult> pubPublishGenerated(
  String name,
  String version, {
  Map<String, String> files = const {},
}) async {
  final directory = await _pubHome.createTemp('package-');
  await File(path.join(directory.path, 'pubspec.yaml')).writeAsString('''
name: $name
description: A package generated by the tests for the publishing policies.
version: $version
homepage: https://example.com
environment:
  sdk: ^3.5.0
''');
  await File(path.join(directory.path, 'LICENSE')).writeAsString('MIT');
  for (final entry in files.entries) {
    await File(path.join(directory.path, entry.key)).writeAsString(entry.value);
  }
  return Process.run('dart', ['pub', 'publish', '--force'],
      workingDirectory: directory.path, environment: _pubEnvironment);
}

/// Forgets the version listings pub cached, as a later run would not trust.
Future<void> clearPubListingCache() async {
  final hosted = Directory(path.join(_pubHome.path, 'cache', 'hosted'));
  if (!await hosted.exists()) return;
  await for (final server in hosted.list()) {
    final cache = Directory(path.join(server.path, '.cache'));
    if (await cache.exists()) await cache.delete(recursive: true);
  }
}

/// A throwaway package that depends on [name] with the [constraint].
Future<Directory> createConsumer(String name, String constraint) async {
  final directory = await _pubHome.createTemp('consumer-');
  await File(path.join(directory.path, 'pubspec.yaml')).writeAsString('''
name: consumer
environment:
  sdk: ^3.5.0
dependencies:
  $name: $constraint
''');
  return directory;
}

Future<ProcessResult> pubGet(Directory consumer) =>
    Process.run('dart', ['pub', 'get'],
        workingDirectory: consumer.path, environment: _pubEnvironment);

/// The version of [name] that `pubspec.lock` in [consumer] holds.
String lockedVersion(Directory consumer, String name) {
  final lock =
      File(path.join(consumer.path, 'pubspec.lock')).readAsStringSync();
  final section = lock.substring(lock.indexOf('  $name:'));
  return RegExp(r'version: "([^"]+)"').firstMatch(section)!.group(1)!;
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
