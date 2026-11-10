import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:mongo_dart/mongo_dart.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';
import 'package:unpub/src/utils.dart';
import 'package:unpub/unpub.dart';

import 'utils.dart';

void main() {
  Db db = Db(testMongoUri);
  late HttpServer server;

  setUpAll(() async {
    await db.open();
    await setUpPubClient();
  });

  Future<Map<String, dynamic>> readMeta(String name) async {
    var res =
        await db.collection(packageCollection).findOne(where.eq('name', name));
    res!.remove('_id'); // TODO: null
    return res;
  }

  Map<String, String> pubspecCache = {};

  Future<String?> readFile(
      String package, String version, String filename) async {
    var key = package + version + filename;
    if (pubspecCache[key] == null) {
      var filePath = path.absolute('test/fixtures', package, version, filename);
      pubspecCache[key] = await File(filePath).readAsString();
    }
    return pubspecCache[key];
  }

  Future<void> cleanUpDb() async {
    await db.dropCollection(packageCollection);
    await db.dropCollection(statsCollection);
  }

  /// Removes the fields computed per upload, after checking their format.
  void stripRegistryFields(dynamic version) {
    expect(version.remove('archive_sha256'), matches(r'^[0-9a-f]{64}$'));
    expect(version.remove('published'), endsWith('Z'));
  }

  tearDownAll(() async {
    await db.close();
    await tearDownPubClient();
  });

  group('publish', () {
    setUpAll(() async {
      await cleanUpDb();
      server = await createServer(email0);
    });

    tearDownAll(() async {
      await server.close();
    });

    test('fresh', () async {
      var version = '0.0.1';

      var result = await pubPublish(package0, version);
      expect(result.stderr, '');

      var meta = await readMeta(package0);

      expect(meta['name'], package0);
      expect(meta['uploaders'], [email0]);
      expect(meta['private'], true);
      expect(meta['createdAt'], isA<DateTime>());
      expect(meta['updatedAt'], isA<DateTime>());
      expect(meta['versions'], isList);
      expect(meta['versions'], hasLength(1));

      var item = meta['versions'][0];
      expect(item['createdAt'], isA<DateTime>());
      item.remove('createdAt');
      expect(item.remove('sha256'), hasLength(64));
      expect(item.remove('archiveLayout'), 'digest');
      expect(
        DeepCollectionEquality().equals(item, {
          'version': version,
          'pubspecYaml': await readFile(package0, version, 'pubspec.yaml'),
          'pubspec':
              loadYamlAsMap(await readFile(package0, version, 'pubspec.yaml')),
          'readme': await readFile(package0, version, 'README.md'),
          'changelog': await readFile(package0, version, 'CHANGELOG.md'),
          'uploader': email0,
        }),
        true,
      );
    });

    test('existing package', () async {
      var version = '0.0.3';

      var result = await pubPublish(package0, version);
      expect(result.stderr, '');

      var meta = await readMeta(package0);

      expect(meta['name'], package0);
      expect(meta['uploaders'], [email0]);
      expect(meta['versions'], isList);
      expect(meta['versions'], hasLength(2));
      expect(meta['versions'][0]['version'], '0.0.1');
      expect(meta['versions'][1]['version'], version);
    });

    test('duplicated version', () async {
      var result = await pubPublish(package0, '0.0.3');
      expect(result.stderr, contains('version invalid'));
    });

    test('no readme and changelog', () async {
      var version = '1.0.0-noreadme';
      await pubPublish(package0, version);

      var meta = await readMeta(package0);

      expect(meta['name'], package0);
      expect(meta['uploaders'], [email0]);
      expect(meta['versions'], isList);
      expect(meta['versions'], hasLength(3));
      expect(meta['versions'][0]['version'], '0.0.1');
      expect(meta['versions'][1]['version'], '0.0.3');

      var item = meta['versions'][2];
      expect(item['createdAt'], isA<DateTime>());
      item.remove('createdAt');
      expect(item.remove('sha256'), hasLength(64));
      expect(item.remove('archiveLayout'), 'digest');
      expect(
        DeepCollectionEquality().equals(item, {
          'version': version,
          'pubspecYaml': await readFile(package0, version, 'pubspec.yaml'),
          'pubspec':
              loadYamlAsMap(await readFile(package0, version, 'pubspec.yaml')),
          'uploader': email0,
        }),
        true,
      );
    });
  });

  group('get versions', () {
    setUpAll(() async {
      await cleanUpDb();
      server = await createServer(email0);
      await pubPublish(package0, '0.0.1');
      await pubPublish(package0, '0.0.2');
    });

    tearDownAll(() async {
      await server.close();
    });

    test('existing at local', () async {
      var res = await getVersions(package0);
      expect(res.statusCode, HttpStatus.ok);

      var body = json.decode(res.body);
      stripRegistryFields(body['latest']);
      (body['versions'] as List).forEach(stripRegistryFields);
      expect(
        DeepCollectionEquality().equals(body, {
          "name": "package_0",
          "isDiscontinued": false,
          "latest": {
            "archive_url":
                "$pubHostedUrl/packages/package_0/versions/0.0.2.tar.gz",
            "pubspec": loadYamlAsMap(
                await readFile('package_0', '0.0.2', 'pubspec.yaml')),
            "version": "0.0.2"
          },
          "versions": [
            {
              "archive_url":
                  "$pubHostedUrl/packages/package_0/versions/0.0.1.tar.gz",
              "pubspec": loadYamlAsMap(
                  await readFile('package_0', '0.0.1', 'pubspec.yaml')),
              "version": "0.0.1"
            },
            {
              "archive_url":
                  "$pubHostedUrl/packages/package_0/versions/0.0.2.tar.gz",
              "pubspec": loadYamlAsMap(
                  await readFile('package_0', '0.0.2', 'pubspec.yaml')),
              "version": "0.0.2"
            }
          ]
        }),
        true,
      );
    });

    test('existing at remote', () async {
      var name = 'http';
      var res = await getVersions(name);
      expect(res.statusCode, HttpStatus.ok);

      var body = json.decode(res.body);
      expect(body['name'], name);
    });

    test('not existing', () async {
      var res = await getVersions(notExistingPacakge);
      expect(res.statusCode, HttpStatus.notFound);
    });
  });

  group('get specific version', () {
    setUpAll(() async {
      await cleanUpDb();
      server = await createServer(email0);
      await pubPublish(package0, '0.0.1');
      await pubPublish(package0, '0.0.3+1');
    });

    tearDownAll(() async {
      await server.close();
    });

    test('existing at local', () async {
      var res = await getSpecificVersion(package0, '0.0.1');
      expect(res.statusCode, HttpStatus.ok);

      var body = json.decode(res.body);
      stripRegistryFields(body);
      expect(
        DeepCollectionEquality().equals(body, {
          "archive_url":
              "$pubHostedUrl/packages/package_0/versions/0.0.1.tar.gz",
          "pubspec": loadYamlAsMap(
              await readFile('package_0', '0.0.1', 'pubspec.yaml')),
          "version": '0.0.1'
        }),
        true,
      );
    });

    test('decode version correctly', () async {
      var res = await getSpecificVersion(package0, '0.0.3+1');
      expect(res.statusCode, HttpStatus.ok);

      var body = json.decode(res.body);
      stripRegistryFields(body);
      expect(
        DeepCollectionEquality().equals(body, {
          "archive_url":
              "$pubHostedUrl/packages/package_0/versions/0.0.3+1.tar.gz",
          "pubspec": loadYamlAsMap(
              await readFile('package_0', '0.0.3+1', 'pubspec.yaml')),
          "version": '0.0.3+1'
        }),
        true,
      );
    });

    test('not existing version at local', () async {
      var res = await getSpecificVersion(package0, '0.0.2');
      expect(res.statusCode, HttpStatus.notFound);
    });

    test('existing at remote', () async {
      var res = await getSpecificVersion('http', '0.12.0+2');
      expect(res.statusCode, HttpStatus.ok);

      var body = json.decode(res.body);
      expect(body['version'], '0.12.0+2');
    });

    test('not existing', () async {
      var res = await getSpecificVersion(notExistingPacakge, '0.0.1');
      expect(res.statusCode, HttpStatus.notFound);
    });
  });

  group('uploader', () {
    setUpAll(() async {
      await cleanUpDb();
      server = await createServer(email0);
      await pubPublish(package0, '0.0.1');
    });

    tearDownAll(() async {
      await server.close();
    });

    group('add', () {
      test('already exists', () async {
        var result = await addUploader(package0, email0);
        expect(result.body, contains('email already exists'));

        var meta = await readMeta(package0);
        expect(meta['uploaders'], unorderedEquals([email0]));
      });

      test('success', () async {
        var result = await addUploader(package0, email1);
        expect(result.statusCode, HttpStatus.ok);

        var meta = await readMeta(package0);
        expect(meta['uploaders'], unorderedEquals([email0, email1]));

        result = await addUploader(package0, email2);
        expect(result.statusCode, HttpStatus.ok);

        meta = await readMeta(package0);
        expect(meta['uploaders'], unorderedEquals([email0, email1, email2]));
      });
    });

    group('remove', () {
      test('not in uploader', () async {
        var result = await removeUploader(package0, email3);
        expect(result.body, contains('email not uploader'));

        var meta = await readMeta(package0);
        expect(meta['uploaders'], unorderedEquals([email0, email1, email2]));
      });

      test('success', () async {
        var result = await removeUploader(package0, email2);
        expect(result.statusCode, HttpStatus.ok);

        var meta = await readMeta(package0);
        expect(meta['uploaders'], unorderedEquals([email0, email1]));

        result = await removeUploader(package0, email1);
        expect(result.statusCode, HttpStatus.ok);

        meta = await readMeta(package0);
        expect(meta['uploaders'], unorderedEquals([email0]));
      });
    });

    group('permission', () {
      setUpAll(() async {
        await server.close();
        server = await createServer(email1);
      });

      tearDownAll(() async {
        await server.close();
      });

      test('add', () async {
        var result = await addUploader(package0, email0);
        expect(result.statusCode, HttpStatus.forbidden);
        expect(result.body, contains('no permission'));
      });

      test('remove', () async {
        var result = await removeUploader(package0, email0);
        expect(result.statusCode, HttpStatus.forbidden);
        expect(result.body, contains('no permission'));
      });
    });
  });

  group('badge', () {
    setUpAll(() async {
      await cleanUpDb();
      server = await createServer(email0);
      await pubPublish(package0, '0.0.1');
    });

    tearDownAll(() async {
      await server.close();
    });

    group('v', () {
      test('<1.0.0', () async {
        var res = await http.Client().send(
            http.Request('GET', baseUri.resolve('/badge/v/$package0'))
              ..followRedirects = false);
        expect(res.statusCode, HttpStatus.found);
        expect(res.headers[HttpHeaders.locationHeader],
            'https://img.shields.io/static/v1?label=unpub&message=0.0.1&color=orange');
      });

      test('>=1.0.0', () async {
        await pubPublish(package0, '1.0.0');

        var res = await http.Client().send(
            http.Request('GET', baseUri.resolve('/badge/v/$package0'))
              ..followRedirects = false);
        expect(res.statusCode, HttpStatus.found);
        expect(res.headers[HttpHeaders.locationHeader],
            'https://img.shields.io/static/v1?label=unpub&message=1.0.0&color=blue');
      });

      test('package not exists', () async {
        var res =
            await http.get(baseUri.resolve('/badge/v/$notExistingPacakge'));
        expect(res.statusCode, HttpStatus.notFound);
      });
    });

    group('d', () {
      test('correct download count', () async {
        var res = await http.Client().send(
            http.Request('GET', baseUri.resolve('/badge/d/$package0'))
              ..followRedirects = false);
        expect(res.statusCode, HttpStatus.found);
        expect(res.headers[HttpHeaders.locationHeader],
            'https://img.shields.io/static/v1?label=downloads&message=0&color=blue');
      });

      test('package not exists', () async {
        var res =
            await http.get(baseUri.resolve('/badge/d/$notExistingPacakge'));
        expect(res.statusCode, HttpStatus.notFound);
      });
    });
  });

  group('tarball', () {
    setUpAll(() async {
      await cleanUpDb();
      server = await createServer(email0);
      await pubPublish(package0, '0.0.1');
    });

    tearDownAll(() async {
      await server.close();
    });

    test('download streams the published archive', () async {
      var res = await http
          .get(baseUri.resolve('/packages/$package0/versions/0.0.1.tar.gz'));
      expect(res.statusCode, HttpStatus.ok);
      expect(res.bodyBytes.take(2), [0x1f, 0x8b]);
    });

    test('download counter increases for pub clients', () async {
      await http.get(
        baseUri.resolve('/packages/$package0/versions/0.0.1.tar.gz'),
        headers: {'user-agent': 'Dart pub 3.12.0'},
      );

      var download = 0;
      for (var i = 0; i < 50 && download == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        download = (await readMeta(package0))['download'] as int;
      }
      expect(download, 1);
    });

    test('daily stats are created on a fresh database', () async {
      Future<Map<String, dynamic>?> findStats() =>
          db.collection(statsCollection).findOne(where.eq('name', package1));

      await pubPublish(package1, '0.0.1');
      expect(await findStats(), isNull);

      Future<void> downloadAndWait(int expected) async {
        await http.get(
          baseUri.resolve('/packages/$package1/versions/0.0.1.tar.gz'),
          headers: {'user-agent': 'Dart pub 3.12.0'},
        );
        var today = DateFormat('yyyyMMdd').format(DateTime.now());
        Map<String, dynamic>? stats;
        for (var i = 0; i < 50 && stats?['d$today'] != expected; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          stats = await findStats();
        }
        stats!.remove('_id');
        expect(stats, {'name': package1, 'd$today': expected});
      }

      await downloadAndWait(1);
      await downloadAndWait(2);
      expect(
          await db
              .collection(statsCollection)
              .count(where.eq('name', package1)),
          1);
    });

    test('dart pub get resolves the published package', () async {
      var result = await pubGetConsumer(package0, '0.0.1');
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    });
  });

  group('web api', () {
    setUpAll(() async {
      await cleanUpDb();
      server = await createServer(email0);
      await pubPublish(package0, '0.0.1');
      await pubPublish(package1, '0.0.1');
    });

    tearDownAll(() async {
      await server.close();
    });

    test('lists packages with the total count', () async {
      var res = await http.get(baseUri.resolve('/webapi/packages?size=1'));
      expect(res.statusCode, HttpStatus.ok);

      var data = json.decode(res.body)['data'];
      expect(data['count'], 2);
      expect(data['packages'], hasLength(1));
    });

    test('searches by keyword', () async {
      var res = await http.get(baseUri.resolve('/webapi/packages?q=package_1'));
      var data = json.decode(res.body)['data'];
      expect(data['count'], 1);
      expect(data['packages'][0]['name'], package1);
    });

    test('keyword search ignores case', () async {
      var res = await http.get(baseUri.resolve('/webapi/packages?q=PACKAGE_1'));
      var data = json.decode(res.body)['data'];
      expect(data['count'], 1);
      expect(data['packages'][0]['name'], package1);
    });

    for (var keyword in ['package.1', 'package_[01]', '.*']) {
      test('keyword search treats $keyword literally', () async {
        var res = await http.get(Uri(
            scheme: baseUri.scheme,
            host: baseUri.host,
            port: baseUri.port,
            path: '/webapi/packages',
            queryParameters: {'q': keyword}));
        expect(res.statusCode, HttpStatus.ok);
        expect(json.decode(res.body)['data']['count'], 0);
      });
    }

    test('a keyword that is not a valid regular expression works', () async {
      var res = await http.get(baseUri.resolve('/webapi/packages?q=pack%28'));
      expect(res.statusCode, HttpStatus.ok);
      expect(json.decode(res.body)['data']['count'], 0);
    });

    test('returns package detail', () async {
      var res =
          await http.get(baseUri.resolve('/webapi/package/$package0/latest'));
      var data = json.decode(res.body)['data'];
      expect(data['name'], package0);
      expect(data['version'], '0.0.1');
      expect(data['uploaders'], [email0]);
    });

    test('lists versions as json', () async {
      var res = await http.get(baseUri.resolve('/packages/$package0.json'));
      expect(json.decode(res.body), {
        'name': package0,
        'versions': ['0.0.1'],
      });
    });

    test('serves the web ui', () async {
      var index = await http.get(baseUri.resolve('/'));
      expect(index.statusCode, HttpStatus.ok);
      expect(index.headers['content-type'], contains('text/html'));
      expect(index.body, contains(package0));

      var script = await http.get(baseUri.resolve('/static/app.js'));
      expect(script.statusCode, HttpStatus.ok);
      expect(script.headers['content-type'], contains('text/javascript'));
    });
  });

  group('authorization', () {
    setUpAll(() async {
      await cleanUpDb();
    });

    tearDown(() async {
      await server.close();
    });

    test('publishing with a wrong token is rejected', () async {
      server = await createServer(email0, token: 'another-token');
      var result = await pubPublish(package0, '0.0.1');
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('Invalid Bearer token'));

      var stored = await db
          .collection(packageCollection)
          .findOne(where.eq('name', package0));
      expect(stored, isNull);
    });

    test('uploader management requires the token', () async {
      server = await createServer(email0);
      var res = await http.post(
        baseUri.resolve('/api/packages/$package0/uploaders'),
        body: 'email=$email1',
      );
      expect(res.statusCode, HttpStatus.unauthorized);
    });
  });

  group('authenticated read access', () {
    setUpAll(() async {
      await cleanUpDb();
      server = await createServer(email0, authenticatedReads: true);
      await addPubToken();
      await pubPublish(package0, '0.0.1');
    });

    tearDownAll(() async {
      await server.close();
    });

    for (var route in [
      '/',
      '/packages/package_0',
      '/api/packages/package_0',
      '/api/packages/package_0/versions/0.0.1',
      '/packages/package_0/versions/0.0.1.tar.gz',
      '/packages/package_0.json',
      '/webapi/packages',
      '/webapi/package/package_0/latest',
      '/badge/v/package_0',
    ]) {
      test('$route needs a token', () async {
        var res = await http.get(baseUri.resolve(route));
        expect(res.statusCode, HttpStatus.unauthorized);
        expect(json.decode(res.body)['error']['message'], contains('Bearer'));
      });
    }

    test('the probes stay open', () async {
      expect((await http.get(baseUri.resolve('/healthz'))).statusCode,
          HttpStatus.ok);
      expect((await http.get(baseUri.resolve('/readyz'))).statusCode,
          HttpStatus.ok);
    });

    test('dart pub get works with the token', () async {
      var result = await pubGetConsumer(package0, '0.0.1');
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    });
  });

  group('personal tokens', () {
    late AccountService accounts;

    setUpAll(() async {
      await cleanUpDb();
      for (final name in [userCollection, tokenCollection, sessionCollection]) {
        await db.dropCollection(name);
      }
      final store = AccountStore(db);
      await store.ensureIndexes();
      accounts = AccountService(store);
    });

    Future<HttpServer> serve(ReadAccess readAccess) async {
      if (Directory(baseDir).existsSync()) {
        await Directory(baseDir).delete(recursive: true);
      }
      await Directory(baseDir).create(recursive: true);
      final store = AccountStore(db);
      return App(
        metaStore: MongoStore(db),
        packageStore: FileStore(baseDir),
        authenticator: ChainAuthenticator([ApiTokenAuthenticator(store)]),
        readAccess: readAccess,
      ).serve('0.0.0.0', 4000);
    }

    tearDownAll(() => addPubToken());

    test('dart pub publish and get work with a user token', () async {
      server = await serve(ReadAccess.authenticated);
      addTearDown(() => server.close());
      final user = await accounts.createUser(
          email: 'dev@example.com', role: Role.publisher);
      final created = await accounts.createToken(user, name: 'laptop');
      await addPubToken(created.secret);

      final published = await pubPublish(package0, '0.0.1');
      expect(published.exitCode, 0,
          reason: '${published.stdout}${published.stderr}');
      expect((await readMeta(package0))['uploaders'], ['dev@example.com']);

      final fetched = await pubGetConsumer(package0, '0.0.1');
      expect(fetched.exitCode, 0, reason: '${fetched.stdout}${fetched.stderr}');
    });

    test('dart pub get without a token is refused when reads are protected',
        () async {
      server = await serve(ReadAccess.authenticated);
      addTearDown(() => server.close());
      await addPubToken('not-a-real-token');

      final fetched = await pubGetConsumer(package0, '0.0.1');
      expect(fetched.exitCode, isNot(0));
      expect(fetched.stderr, contains('Invalid Bearer token'));
    });

    test('a read-only token cannot dart pub publish', () async {
      server = await serve(ReadAccess.public);
      addTearDown(() => server.close());
      final user = await accounts.createUser(
          email: 'ci@example.com', role: Role.publisher);
      final created =
          await accounts.createToken(user, name: 'ci', scopes: {Scope.read});
      await addPubToken(created.secret);

      final published = await pubPublish(package1, '0.0.1');
      expect(published.exitCode, isNot(0));
      expect(published.stderr, contains('read-only'));
    });
  });

  group('ready', () {
    setUpAll(() async {
      server = await createServer(email0);
    });

    tearDownAll(() async {
      await server.close();
    });

    test('reports mongo and storage as ok', () async {
      var res = await http.get(baseUri.resolve('/readyz'));
      expect(res.statusCode, HttpStatus.ok);
      expect(json.decode(res.body), {
        'status': 'ok',
        'checks': {
          'mongo': {'status': 'ok'},
          'storage': {'status': 'ok'},
        },
      });
    });
  });
}
