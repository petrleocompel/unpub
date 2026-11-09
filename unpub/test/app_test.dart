import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';
import 'package:unpub/unpub.dart';

class FakeMetaStore extends MetaStore {
  Object? healthError;
  UnpubPackage? package;
  final queried = <String>[];
  final added = <String>[];
  final downloads = <String>[];

  @override
  Future<void> checkHealth() async {
    if (healthError != null) throw healthError!;
  }

  @override
  Future<void> addUploader(String name, String email) async {}

  @override
  Future<void> addVersion(String name, UnpubVersion version) async {
    added.add('$name@${version.version}');
  }

  @override
  void increaseDownloads(String name, String version) {
    downloads.add('$name@$version');
  }

  @override
  Future<UnpubPackage?> queryPackage(String name) async {
    queried.add(name);
    return package;
  }

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

const authorized = {'authorization': 'Bearer secret'};

/// A `dart pub publish` request for an archive holding [pubspec].
shelf.Request uploadRequest(String pubspec) {
  const boundary = 'test-boundary';
  final archive = Archive()
    ..addFile(ArchiveFile.string('pubspec.yaml', pubspec));
  final tarball = GZipEncoder().encodeBytes(TarEncoder().encodeBytes(archive));
  return shelf.Request(
    'POST',
    Uri.parse('http://internal:4000/api/packages/versions/newUpload'),
    headers: {
      ...authorized,
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

    test('readyz never exposes a connection string', () async {
      metaStore.healthError =
          'cannot reach mongodb://user:hunter2@db:27017/pub?x=y';
      var response = await createApp().handler(get('/readyz'));
      var body = await response.readAsString();
      expect(body, isNot(contains('hunter2')));
      expect(body, contains('mongodb://***@db:27017/pub'));
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

  group('routes without the auth middleware', () {
    final routes = [
      ['POST', '/api/packages/versions/newUpload'],
      ['POST', '/api/packages/fine/uploaders'],
      ['DELETE', '/api/packages/fine/uploaders/a%40b.c'],
    ];

    for (var route in routes) {
      test('${route[0]} ${route[1]} is a JSON 401', () async {
        var response = await createApp().router.call(shelf.Request(
            route[0], Uri.parse('http://internal:4000${route[1]}'),
            body: 'email=a%40b.c'));
        expect(response.statusCode, HttpStatus.unauthorized);
        expect(response.headers['content-type'], contains('json'));
        expect(json.decode(await response.readAsString())['error']['message'],
            'Authentication is required.');
      });
    }
  });

  group('uploader requests', () {
    final requests = [
      () => shelf.Request(
          'POST', Uri.parse('http://internal:4000/api/packages/fine/uploaders'),
          headers: authorized, body: 'email=new%40b.c'),
      () => shelf.Request(
          'DELETE',
          Uri.parse(
              'http://internal:4000/api/packages/fine/uploaders/new%40b.c'),
          headers: authorized),
    ];
    UnpubPackage packageWith(List<String>? uploaders) => UnpubPackage(
        'fine', [], true, uploaders, DateTime.now(), DateTime.now(), 0);

    for (var request in requests) {
      test('${request().method} needs an uploaders list', () async {
        metaStore.package = packageWith(null);
        var response = await createApp().handler(request());
        expect(response.statusCode, HttpStatus.forbidden);
      });

      test('${request().method} needs an existing package', () async {
        var response = await createApp().handler(request());
        expect(response.statusCode, HttpStatus.forbidden);
      });

      test('${request().method} needs the operator listed', () async {
        metaStore.package = packageWith(['other@b.c']);
        var response = await createApp().handler(request());
        expect(response.statusCode, HttpStatus.forbidden);
      });
    }

    test('adding without an email is a 400', () async {
      var response = await createApp().handler(shelf.Request(
          'POST', Uri.parse('http://internal:4000/api/packages/fine/uploaders'),
          headers: authorized, body: 'other=1'));
      expect(response.statusCode, HttpStatus.badRequest);
    });
  });

  group('package names and versions', () {
    late Directory temp;
    late String baseDir;
    late App app;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('unpub-traversal-');
      baseDir = path.join(temp.path, 'a', 'b', 'packages');
      await Directory(baseDir).create(recursive: true);
      app = App(
        metaStore: metaStore,
        packageStore: FileStore(baseDir),
        authenticator: const BootstrapTokenAuthenticator(token: 'secret'),
      );
    });

    tearDown(() => temp.delete(recursive: true));

    List<String> storedFiles() => temp
        .listSync(recursive: true)
        .whereType<File>()
        .map((file) => file.path)
        .toList();

    Future<void> expectRejected(String pubspec, String message) async {
      var response = await app.handler(uploadRequest(pubspec));
      expect(response.statusCode, HttpStatus.found);
      var location = Uri.parse(response.headers['location']!);
      expect(location.path, '/api/packages/versions/newUploadFinish');

      var finish = await app.handler(get(
          location.toString().replaceFirst(
                'http://internal:4000',
                '',
              ),
          headers: authorized));
      expect(finish.statusCode, HttpStatus.badRequest);
      expect(json.decode(await finish.readAsString())['error']['message'],
          contains(message));
      expect(storedFiles(), isEmpty);
      expect(metaStore.added, isEmpty);
    }

    for (var name in [
      '../../escaped',
      '..',
      'a/b',
      r'a\\b',
      'Upper',
      '1abc',
      'a-b',
      '123',
      'x' * 65,
    ]) {
      test('an upload named "$name" is rejected', () async {
        await expectRejected(
            'name: "$name"\nversion: 1.0.0\n', 'Invalid package name');
      });
    }

    for (var version in [
      '../../escaped',
      '1.0.0/../../escaped',
      'nope',
      '1.0',
    ]) {
      test('an upload with version "$version" is rejected', () async {
        await expectRejected(
            'name: fine\nversion: "$version"\n', 'Invalid package version');
      });
    }

    test('a non-string version is rejected', () async {
      await expectRejected('name: fine\nversion: 1.0\n', 'version');
    });

    test('a valid upload is stored', () async {
      var response =
          await app.handler(uploadRequest('name: fine\nversion: 1.0.0+1\n'));
      expect(response.headers['location'], isNot(contains('error')));
      expect(metaStore.added, ['fine@1.0.0+1']);
      expect(storedFiles(), [path.join(baseDir, 'fine-1.0.0+1.tar.gz')]);
    });

    test('the rejection reason survives the redirect intact', () async {
      var response =
          await app.handler(uploadRequest('name: "a#b&c=d"\nversion: 1.0.0\n'));
      var location = Uri.parse(response.headers['location']!);
      expect(location.fragment, isEmpty);
      expect(location.queryParameters.keys, ['error']);
    });

    const invalidUrls = [
      ['GET', '/packages/..%2F..%2Fsecret/versions/1.0.0.tar.gz'],
      ['GET', '/packages/fine/versions/..%2F..%2Fsecret.tar.gz'],
      ['GET', '/packages/fine/versions/%2e%2e%2Fsecret.tar.gz'],
      ['GET', '/packages/fine/versions/%ZZ.tar.gz'],
      ['GET', '/api/packages/..%2Fsecret'],
      ['GET', '/api/packages/..%2Fsecret/versions/1.0.0'],
      ['GET', '/api/packages/fine/versions/..%2Fsecret'],
      ['GET', '/packages/..%2Fsecret.json'],
      ['GET', '/webapi/package/..%2Fsecret/latest'],
      ['GET', '/webapi/package/fine/..%2Fsecret'],
      ['GET', '/badge/v/..%2Fsecret'],
      ['POST', '/api/packages/..%2Fsecret/uploaders'],
      ['DELETE', '/api/packages/..%2Fsecret/uploaders/a%40b.c'],
    ];

    for (var route in invalidUrls) {
      test('${route[0]} ${route[1]} is a 404 that skips the stores', () async {
        var response = await app.handler(shelf.Request(
            route[0], Uri.parse('http://internal:4000${route[1]}'),
            headers: authorized, body: 'email=a%40b.c'));
        expect(response.statusCode, HttpStatus.notFound);
        expect(metaStore.queried, isEmpty);
      });
    }
  });

  group('download', () {
    late Directory temp;
    late App app;
    final pubClient = {'user-agent': 'Dart pub 3.12.0'};

    UnpubVersion version(String version) => UnpubVersion(
        version, {'name': 'fine'}, null, null, null, null, DateTime.now());

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('unpub-download-');
      metaStore.package = UnpubPackage(
        'fine',
        [version('1.0.0'), version('1.0.0+1')],
        true,
        ['a@b.c'],
        DateTime.now(),
        DateTime.now(),
        0,
      );
      app = App(
        metaStore: metaStore,
        packageStore: FileStore(temp.path),
        authenticator: const BootstrapTokenAuthenticator(token: 'secret'),
      );
    });

    tearDown(() => temp.delete(recursive: true));

    test('a version missing from the metadata is a 404', () async {
      var response = await app.handler(
          get('/packages/fine/versions/9.9.9.tar.gz', headers: pubClient));
      expect(response.statusCode, HttpStatus.notFound);
      expect(metaStore.downloads, isEmpty);
    });

    test('an archive missing from storage is an uncounted 404', () async {
      var response = await app.handler(
          get('/packages/fine/versions/1.0.0.tar.gz', headers: pubClient));
      expect(response.statusCode, HttpStatus.notFound);
      expect(metaStore.downloads, isEmpty);
      expect(json.decode(await response.readAsString())['error'], isNotNull);
    });

    test('a stored archive is streamed and counted', () async {
      File(path.join(temp.path, 'fine-1.0.0.tar.gz'))
          .writeAsBytesSync([1, 2, 3]);
      var response = await app.handler(
          get('/packages/fine/versions/1.0.0.tar.gz', headers: pubClient));
      expect(response.statusCode, HttpStatus.ok);
      expect(
          await response.read().expand((bytes) => bytes).toList(), [1, 2, 3]);
      expect(metaStore.downloads, ['fine@1.0.0']);
    });

    for (var segment in ['1.0.0+1', '1.0.0%2B1']) {
      test('the version segment $segment finds the archive', () async {
        File(path.join(temp.path, 'fine-1.0.0+1.tar.gz')).writeAsBytesSync([1]);
        var response =
            await app.handler(get('/packages/fine/versions/$segment.tar.gz'));
        expect(response.statusCode, HttpStatus.ok);
      });
    }
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
