import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';
import 'package:unpub/unpub.dart';

class FakeMetaStore extends MetaStore {
  Object? healthError;
  UnpubPackage? package;

  @override
  Future<void> checkHealth() async {
    if (healthError != null) throw healthError!;
  }

  @override
  Future<void> addUploader(String name, String email) async {}

  @override
  Future<void> addVersion(String name, UnpubVersion version) async {}

  @override
  void increaseDownloads(String name, String version) {}

  @override
  Future<UnpubPackage?> queryPackage(String name) async => package;

  @override
  Future<UnpubQueryResult> queryPackages({
    required int size,
    required int page,
    required String sort,
    String? keyword,
    String? uploader,
    String? dependency,
  }) async =>
      UnpubQueryResult(0, []);

  @override
  Future<void> removeUploader(String name, String email) async {}
}

class FakePackageStore extends PackageStore {
  Object? healthError;

  @override
  Future<void> checkHealth() async {
    if (healthError != null) throw healthError!;
  }

  @override
  Future<void> upload(String name, String version, List<int> content) async {}
}

shelf.Request get(String path, {Map<String, String>? headers}) =>
    shelf.Request('GET', Uri.parse('http://internal:4000$path'),
        headers: headers);

void main() {
  late FakeMetaStore metaStore;
  late FakePackageStore packageStore;

  App createApp({Uri? publicUrl}) => App(
        metaStore: metaStore,
        packageStore: packageStore,
        authenticator: const BootstrapTokenAuthenticator(token: 'secret'),
        publicUrl: publicUrl,
      );

  setUp(() {
    metaStore = FakeMetaStore();
    packageStore = FakePackageStore();
  });

  group('health', () {
    test('healthz is independent of the stores', () async {
      metaStore.healthError = 'down';
      var response = await createApp().handler(get('/healthz'));
      expect(response.statusCode, HttpStatus.ok);
    });

    test('readyz is ok when both stores are', () async {
      var response = await createApp().handler(get('/readyz'));
      expect(response.statusCode, HttpStatus.ok);
      expect(json.decode(await response.readAsString())['status'], 'ok');
    });

    test('readyz reports a failing metadata store', () async {
      metaStore.healthError = 'connection refused';
      var response = await createApp().handler(get('/readyz'));
      expect(response.statusCode, HttpStatus.serviceUnavailable);
      expect(json.decode(await response.readAsString()), {
        'status': 'unavailable',
        'checks': {
          'mongo': {'status': 'error', 'error': 'connection refused'},
          'storage': {'status': 'ok'},
        },
      });
    });

    test('readyz reports a failing package store', () async {
      packageStore.healthError = 'read only';
      var response = await createApp().handler(get('/readyz'));
      expect(response.statusCode, HttpStatus.serviceUnavailable);
      var checks = json.decode(await response.readAsString())['checks'];
      expect(checks['mongo'], {'status': 'ok'});
      expect(checks['storage']['error'], 'read only');
    });
  });

  group('public url', () {
    const auth = {'authorization': 'Bearer secret'};

    test('builds upload urls', () async {
      var app = createApp(publicUrl: Uri.parse('https://pub.example.com'));
      var response =
          await app.handler(get('/api/packages/versions/new', headers: auth));
      expect(json.decode(await response.readAsString())['url'],
          'https://pub.example.com/api/packages/versions/newUpload');
    });

    test('defaults to the request url', () async {
      var response = await createApp()
          .handler(get('/api/packages/versions/new', headers: auth));
      expect(json.decode(await response.readAsString())['url'],
          'http://internal:4000/api/packages/versions/newUpload');
    });

    test('ignores the removed proxy-origin header', () async {
      var response = await createApp().handler(get('/api/packages/versions/new',
          headers: {...auth, 'proxy-origin': 'https://evil.example.com'}));
      expect(await response.readAsString(), isNot(contains('evil')));
    });
  });

  group('errors', () {
    late Logger logger;
    late List<LogRecord> records;

    setUp(() {
      logger = Logger.root;
      logger.level = Level.ALL;
      records = [];
      logger.onRecord.listen(records.add);
    });

    tearDown(() => logger.clearListeners());

    test('a store failure is a logged 500', () async {
      final failing = _ThrowingMetaStore();
      var app = App(
        metaStore: failing,
        packageStore: packageStore,
        authenticator: const BootstrapTokenAuthenticator(token: 'secret'),
      );
      var response = await app.handler(get('/api/packages/foo'));
      expect(response.statusCode, HttpStatus.internalServerError);

      var record = records.singleWhere((r) => r.level == Level.SEVERE);
      expect(record.message, contains('status=500'));
      expect(record.error, isA<StateError>());
    });

    test('every request logs method, path, status and duration', () async {
      await createApp().handler(get('/healthz'));
      var event = records.single.object as LogEvent;
      expect(event.fields['method'], 'GET');
      expect(event.fields['path'], '/healthz');
      expect(event.fields['status'], 200);
      expect(event.fields['durationMs'], isA<int>());
    });
  });
}

class _ThrowingMetaStore extends FakeMetaStore {
  @override
  Future<UnpubPackage?> queryPackage(String name) =>
      Future.error(StateError('no connection'));
}
