import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:mongo_dart/mongo_dart.dart';
import 'package:test/test.dart';
import 'package:unpub/unpub.dart';

import 'utils.dart';

const _name = 'contested';
const _token = 'token';
const _auth = {'authorization': 'Bearer $_token'};

/// A [FileStore] that can stop in the middle of storing an archive.
class _PausingStore extends FileStore {
  Completer<void>? reached;
  Completer<void>? resume;
  Object? failure;

  _PausingStore(super.baseDir);

  @override
  Future<void> upload(String name, String version, List<int> content) async {
    reached?.complete();
    await resume?.future;
    final error = failure;
    if (error != null) throw error;
    await super.upload(name, version, content);
  }
}

void main() {
  late Db db;
  late Directory storage;

  Future<void> clean() async {
    await db.dropCollection(packageCollection);
    await db.dropCollection(uploadReservationsCollection);
  }

  App buildApp({
    PackageStore? packageStore,
    Future<void> Function(Map<String, dynamic>, String)? uploadValidator,
    PublishConfig publish = const PublishConfig(),
  }) =>
      App(
        metaStore: MongoStore(db),
        packageStore: packageStore ?? FileStore(storage.path),
        authenticator: const FakeAuthenticator(_token, 'dev@b.c'),
        publishPolicy: PublishPolicy(publish),
        uploadValidator: uploadValidator,
      );

  String pubspec(String description, {String version = '1.0.0'}) =>
      'name: $_name\nversion: $version\ndescription: $description\n';

  /// The error of an upload, or null if it succeeded.
  Future<String?> upload(App app, String description,
      {String version = '1.0.0'}) async {
    final response = await app
        .handler(uploadRequest(pubspec(description, version: version), _auth));
    return Uri.parse(response.headers['location']!).queryParameters['error'];
  }

  Future<Map<String, dynamic>> storedVersion([String version = '1.0.0']) async {
    final package =
        await db.collection(packageCollection).findOne(where.eq('name', _name));
    return (package!['versions'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((item) => item['version'] == version);
  }

  /// The hash of the stored archive must be the one recorded for the version,
  /// and [description] the content of the upload that won.
  Future<void> expectConsistent(String description) async {
    final stored = await storedVersion();
    expect(stored['pubspec']['description'], description);
    final bytes = File('${storage.path}/$_name-1.0.0.tar.gz').readAsBytesSync();
    expect(crypto.sha256.convert(bytes).toString(), stored['sha256']);
  }

  Future<List<Map<String, dynamic>>> reservations() => db
      .collection(uploadReservationsCollection)
      .find(where.eq('name', _name))
      .toList();

  setUpAll(() async {
    db = Db(testMongoUri);
    await db.open();
  });

  tearDownAll(() async {
    await clean();
    await db.close();
  });

  setUp(() async {
    await clean();
    await MongoStore(db).ensureIndexes();
    storage = await Directory.systemTemp.createTemp('unpub-concurrency-');
    addTearDown(() => storage.delete(recursive: true));
  });

  group('in one process', () {
    test('a second upload during the validator is refused', () async {
      final entered = Completer<void>();
      final resume = Completer<void>();
      final app = buildApp(uploadValidator: (spec, _) async {
        if (spec['description'] == 'first') {
          entered.complete();
          await resume.future;
        }
      });

      final first = upload(app, 'first');
      await entered.future;

      expect(await upload(app, 'second'),
          contains('version is being published by another request'));

      resume.complete();
      expect(await first, isNull);
      await expectConsistent('first');
    });

    test('the validator runs after the package is claimed', () async {
      final validated = <String>[];
      final app = buildApp(uploadValidator: (spec, _) async {
        validated.add(spec['description'] as String);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });

      final results =
          await Future.wait([upload(app, 'one'), upload(app, 'two')]);

      expect(results.where((error) => error == null), hasLength(1));
      expect(validated, hasLength(1));
      await expectConsistent(validated.single);
    });

    test('the version can be published once the first one is done', () async {
      final app =
          buildApp(publish: const PublishConfig(requireVersionBump: false));
      expect(await upload(app, 'first'), isNull);
      expect(await upload(app, 'second'), isNull);
      await expectConsistent('second');
    });

    test('a different version is not held up', () async {
      final entered = Completer<void>();
      final resume = Completer<void>();
      final app = buildApp(uploadValidator: (spec, _) async {
        if (spec['version'] == '1.0.0') {
          entered.complete();
          await resume.future;
        }
      });

      final first = upload(app, 'first');
      await entered.future;
      expect(await upload(app, 'other', version: '2.0.0'), isNull);
      resume.complete();
      expect(await first, isNull);
    });
  });

  group('across processes', () {
    test('a second server is refused while the archive is written', () async {
      final store = _PausingStore(storage.path)
        ..reached = Completer<void>()
        ..resume = Completer<void>();
      final firstServer = buildApp(packageStore: store);
      final secondServer = buildApp();

      final first = upload(firstServer, 'first');
      await store.reached!.future;

      expect(await upload(secondServer, 'second'),
          contains('version is being published by another request'));

      store.resume!.complete();
      expect(await first, isNull);
      await expectConsistent('first');
    });

    test('a server that resumes after the other published stores nothing',
        () async {
      final entered = Completer<void>();
      final resume = Completer<void>();
      final slowServer = buildApp(uploadValidator: (_, __) async {
        entered.complete();
        await resume.future;
      });
      final fastServer = buildApp();

      final slow = upload(slowServer, 'slow');
      await entered.future;
      expect(await upload(fastServer, 'fast'), isNull);

      resume.complete();

      expect(await slow, contains('already exists'));
      await expectConsistent('fast');
    });

    test('concurrent servers leave one consistent version', () async {
      final servers = [for (var i = 0; i < 8; i++) buildApp()];

      final results = await Future.wait(
          [for (var i = 0; i < 8; i++) upload(servers[i], 'upload $i')]);

      final winner = results.indexOf(null);
      expect(results.where((error) => error == null), hasLength(1));
      await expectConsistent('upload $winner');
      expect(await reservations(), isEmpty);
    });

    test('a reservation left by a dead server blocks until it expires',
        () async {
      await db.collection(uploadReservationsCollection).insertOne({
        'name': _name,
        'version': '1.0.0',
        'reservation': 'dead',
        'createdAt': DateTime.now(),
        'expiresAt': DateTime.now().add(const Duration(minutes: 15)),
      });

      expect(await upload(buildApp(), 'blocked'),
          contains('version is being published by another request'));
      expect(File('${storage.path}/$_name-1.0.0.tar.gz').existsSync(), isFalse);
    });

    test('releasing only drops the reservation of that upload', () async {
      final meta = MongoStore(db);
      final held = await meta.reserveUpload(_name, '1.0.0');
      expect(held, isNotNull);
      expect(await meta.reserveUpload(_name, '1.0.0'), isNull);

      await meta.releaseUpload(_name, '1.0.0', 'someone-else');
      expect(await reservations(), hasLength(1));

      await meta.releaseUpload(_name, '1.0.0', held!);
      expect(await reservations(), isEmpty);
    });
  });

  group('the reservation', () {
    test('is gone after a successful publish', () async {
      expect(await upload(buildApp(), 'first'), isNull);
      expect(await reservations(), isEmpty);
    });

    test('is gone after the store fails', () async {
      final store = _PausingStore(storage.path)..failure = 'disk full';

      expect(await upload(buildApp(packageStore: store), 'first'),
          contains('disk full'));

      expect(await reservations(), isEmpty);
      store.failure = null;
      expect(await upload(buildApp(packageStore: store), 'first'), isNull);
    });

    test('is not taken for an upload the policies refuse', () async {
      final app = buildApp(
          publish: const PublishConfig(allowedNamePrefixes: ['other_']));
      expect(await upload(app, 'first'), contains('allowedNamePrefixes'));
      expect(await reservations(), isEmpty);
    });

    test('has a unique index and expires by itself', () async {
      await MongoStore(db).ensureIndexes();
      final indexes =
          await db.collection(uploadReservationsCollection).getIndexes();
      expect(indexes.singleWhere((i) => i['name'] == 'name_version')['unique'],
          isTrue);
      expect(
          indexes.singleWhere(
              (i) => i['name'] == 'expires_at_ttl')['expireAfterSeconds'],
          0);
    });

    test('expires 15 minutes after it was taken', () async {
      final before = DateTime.now();
      await MongoStore(db).reserveUpload(_name, '1.0.0');
      final expires = (await reservations()).single['expiresAt'] as DateTime;
      expect(expires.difference(before).inMinutes, inInclusiveRange(14, 15));
    });
  });
}
