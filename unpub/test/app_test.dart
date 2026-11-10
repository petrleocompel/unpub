import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';
import 'package:unpub/unpub.dart';

import 'utils.dart' as utils;

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
  Future<bool> replaceVersion(String name, UnpubVersion version,
          {required String? expectedSha256}) async =>
      true;

  @override
  Future<int> versionDownloads(String name, String version) async => 0;

  @override
  Future<bool> setVersionRetracted(
    String name,
    String version, {
    required bool retracted,
    DateTime? retractedAt,
    String? retractedBy,
  }) async =>
      true;

  @override
  Future<void> setDiscontinued(
    String name, {
    required bool discontinued,
    String? replacedBy,
    DateTime? discontinuedAt,
  }) async {}

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
    bool includeDiscontinued = true,
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
shelf.Request uploadRequest(String pubspec) =>
    utils.uploadRequest(pubspec, authorized);

void main() {
  late FakeMetaStore metaStore;
  late FakePackageStore packageStore;

  App createApp({Uri? publicUrl, Authenticator? authenticator}) => App(
        metaStore: metaStore,
        packageStore: packageStore,
        authenticator: authenticator ??
            const StaticTokenAuthenticator(bootstrapToken: 'secret'),
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

    test('metrics leave the package counts out by default', () async {
      expect(await metaStore.counts(), isNull);
      final response = await createApp().handler(get('/metrics'));
      expect(response.statusCode, HttpStatus.ok);
      final body = await response.readAsString();
      expect(body, isNot(contains('unpub_packages')));
      expect(body, isNot(contains('unpub_versions')));
      expect(body, contains('unpub_mongo_up 1'));
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
    App publisherApp() => createApp(
        authenticator: const utils.FakeAuthenticator('secret', 'me@b.c'));

    for (var request in requests) {
      test('${request().method} needs an uploaders list', () async {
        metaStore.package = packageWith(null);
        var response = await publisherApp().handler(request());
        expect(response.statusCode, HttpStatus.forbidden);
      });

      test('${request().method} needs an existing package', () async {
        var response = await publisherApp().handler(request());
        expect(response.statusCode, HttpStatus.forbidden);
      });

      test('${request().method} needs the operator listed', () async {
        metaStore.package = packageWith(['other@b.c']);
        var response = await publisherApp().handler(request());
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
        authenticator: const StaticTokenAuthenticator(bootstrapToken: 'secret'),
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
      expect(storedFiles().single,
          matches(RegExp(r'/fine/fine-1\.0\.0\+1-[0-9a-f]{64}\.tar\.gz$')));
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

  group('upload size', () {
    test('a declared length over the limit is refused unread', () async {
      final app = App(
        metaStore: metaStore,
        packageStore: packageStore,
        authenticator: const StaticTokenAuthenticator(bootstrapToken: 'secret'),
        publishPolicy: const PublishPolicy(PublishConfig(maxArchiveBytes: 10)),
      );

      final response = await app.handler(shelf.Request(
        'POST',
        Uri.parse('http://internal:4000/api/packages/versions/newUpload'),
        headers: {
          ...authorized,
          'content-type': 'multipart/form-data; boundary=x',
        },
        body: List<int>.filled(70000, 65),
      ));

      expect(response.statusCode, HttpStatus.found);
      final error =
          Uri.parse(response.headers['location']!).queryParameters['error'];
      expect(error, contains('publish.maxArchiveBytes'));
      expect(metaStore.added, isEmpty);
    });
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
        authenticator: const StaticTokenAuthenticator(bootstrapToken: 'secret'),
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
        authenticator: const StaticTokenAuthenticator(bootstrapToken: 'secret'),
      );
      var response = await app.handler(get('/api/packages/foo'));
      expect(response.statusCode, HttpStatus.internalServerError);

      var record = records.singleWhere((r) => r.level == Level.SEVERE);
      expect(record.message, contains('status=500'));
      expect(record.error, isA<StateError>());
    });

    App failingApp() => App(
          metaStore: _ThrowingMetaStore(),
          packageStore: packageStore,
          authenticator:
              const StaticTokenAuthenticator(bootstrapToken: 'secret'),
        );

    test('a 500 carries the request id in the header, body and log', () async {
      final response = await failingApp().handler(get('/api/packages/foo'));
      expect(response.statusCode, HttpStatus.internalServerError);
      final id = response.headers['x-request-id']!;
      expect(id, matches(RegExp(r'^[0-9a-f]{32}$')));
      final body = await response.readAsString();
      expect(response.headers['content-length'], '${utf8.encode(body).length}');
      expect(json.decode(body), {
        'error': {
          'code': 'server_error',
          'message': 'Internal Server Error',
          'requestId': id,
        },
      });
      final record = records.singleWhere((r) => r.level == Level.SEVERE);
      expect((record.object as LogEvent).fields['requestId'], id);
      expect(record.message, contains('requestId=$id'));
    });

    test('a 500 page shows the request id', () async {
      final response = await failingApp().handler(get('/packages/foo',
          headers: {'accept': 'text/html', 'x-request-id': 'edge-42.a_b'}));
      expect(response.statusCode, HttpStatus.internalServerError);
      expect(response.headers['x-request-id'], 'edge-42.a_b');
      final page = await response.readAsString();
      expect(page, contains('Something went wrong'));
      expect(page, contains('<code>edge-42.a_b</code>'));
      expect(
          records.where((r) => r.level == Level.SEVERE).map((r) => r.message),
          contains(contains('(request edge-42.a_b)')));
    });

    test('every answer has a request id, an incoming sane one kept', () async {
      final app = createApp();
      final fresh = await app.handler(get('/healthz'));
      final other = await app.handler(get('/healthz'));
      expect(fresh.headers['x-request-id'], matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(
          other.headers['x-request-id'], isNot(fresh.headers['x-request-id']));
      final event = records.first.object as LogEvent;
      expect(event.fields['requestId'], fresh.headers['x-request-id']);

      final notFound = await app.handler(
          get('/api/packages/nothing', headers: {'x-request-id': 'abc'}));
      expect(notFound.headers['x-request-id'], 'abc');
      expect(await notFound.readAsString(), isNot(contains('requestId')));

      for (final insane in [
        '',
        'a' * 65,
        'has space',
        'semi;colon',
        'a,b',
        'ünï',
      ]) {
        final reply = await app
            .handler(get('/healthz', headers: {'x-request-id': insane}));
        expect(
            reply.headers['x-request-id'], matches(RegExp(r'^[0-9a-f]{32}$')),
            reason: insane);
      }
      final longest = 'a' * 64;
      expect(
          (await app
                  .handler(get('/healthz', headers: {'x-request-id': longest})))
              .headers['x-request-id'],
          longest);
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
