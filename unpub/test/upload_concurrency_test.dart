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
  Future<void> stageArchive(
      String name, String version, String id, List<int> content) async {
    if (reached?.isCompleted == false) reached!.complete();
    await resume?.future;
    final error = failure;
    if (error != null) throw error;
    await super.stageArchive(name, version, id, content);
  }
}

/// A [MongoStore] that always loses the race for a new version.
class _LosingMetaStore extends MongoStore {
  _LosingMetaStore(super.db);

  @override
  Future<bool> addVersion(String name, UnpubVersion version) async => false;
}

/// Counts how often a reservation is renewed.
class _RenewalCountingStore extends MongoStore {
  int renewals = 0;

  _RenewalCountingStore(super.db);

  @override
  Future<bool> renewUpload(String name, String version, String reservation) {
    renewals++;
    return super.renewUpload(name, version, reservation);
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
    MetaStore? metaStore,
  }) =>
      App(
        metaStore: metaStore ?? MongoStore(db),
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

  File finalFile() => File('${storage.path}/$_name-1.0.0.tar.gz');

  List<String> stagedFiles() => [
        for (final entity in storage.listSync())
          if (entity.path.endsWith('.staging')) entity.path,
      ];

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

    test('only its holder can renew a reservation', () async {
      final meta = MongoStore(db);
      final held = await meta.reserveUpload(_name, '1.0.0');
      final before = (await reservations()).single['expiresAt'] as DateTime;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(await meta.renewUpload(_name, '1.0.0', 'someone-else'), isFalse);
      expect((await reservations()).single['expiresAt'], before);

      expect(await meta.renewUpload(_name, '1.0.0', held!), isTrue);
      expect(
          ((await reservations()).single['expiresAt'] as DateTime)
              .isAfter(before),
          isTrue);

      await meta.releaseUpload(_name, '1.0.0', held);
      expect(await meta.renewUpload(_name, '1.0.0', held), isFalse);
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

  group('staging', () {
    test('a publisher stalled past its reservation cannot replace the winner',
        () async {
      final store = _PausingStore(storage.path)
        ..reached = Completer<void>()
        ..resume = Completer<void>();
      final stalled = upload(buildApp(packageStore: store), 'stalled');
      await store.reached!.future;

      // What the TTL index does once the reservation has run out.
      await db
          .collection(uploadReservationsCollection)
          .deleteMany(where.eq('name', _name));
      expect(await upload(buildApp(), 'winner'), isNull);
      final winnerBytes = finalFile().readAsBytesSync();

      store.resume!.complete();

      expect(await stalled, contains('already exists'));
      expect(finalFile().readAsBytesSync(), winnerBytes);
      await expectConsistent('winner');
      expect(stagedFiles(), isEmpty);
    });

    test('the final path appears only after the metadata is won', () async {
      final store = _PausingStore(storage.path)
        ..reached = Completer<void>()
        ..resume = Completer<void>();
      final running = upload(buildApp(packageStore: store), 'first');
      await store.reached!.future;
      expect(finalFile().existsSync(), isFalse);

      store.resume!.complete();

      expect(await running, isNull);
      expect(finalFile().existsSync(), isTrue);
      expect(stagedFiles(), isEmpty);
    });

    test('losing the metadata write never touches the final path', () async {
      final error =
          await upload(buildApp(metaStore: _LosingMetaStore(db)), 'first');

      expect(error, contains('already exists'));
      expect(finalFile().existsSync(), isFalse);
      expect(stagedFiles(), isEmpty);
    });

    test('an archive no version accounts for is reported, not overwritten',
        () async {
      finalFile().writeAsStringSync('left behind');

      final error = await upload(buildApp(), 'first');

      expect(error, contains('storage is corrupt'));
      expect(finalFile().readAsStringSync(), 'left behind');
      expect(await db.collection(packageCollection).findOne(), isNull);
      expect(stagedFiles(), isEmpty);
      expect(await reservations(), isEmpty);
    });

    test('a failing write leaves nothing staged', () async {
      final store = _PausingStore(storage.path)..failure = 'disk full';
      expect(await upload(buildApp(packageStore: store), 'first'),
          contains('disk full'));
      expect(stagedFiles(), isEmpty);
      expect(finalFile().existsSync(), isFalse);
    });

    test('replacing a version commits over the old archive', () async {
      final app =
          buildApp(publish: const PublishConfig(requireVersionBump: false));
      expect(await upload(app, 'first'), isNull);
      final first = finalFile().readAsBytesSync();
      expect(await upload(app, 'second'), isNull);
      expect(finalFile().readAsBytesSync(), isNot(first));
      expect(stagedFiles(), isEmpty);
    });
  });

  test('the server clears crash leftovers when it starts', () async {
    final left = File('${storage.path}/$_name-1.0.0.tar.gz.abc.staging')
      ..writeAsStringSync('partial')
      ..setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 2)));
    final server = await UnpubServer.start(Config.parse(
      '''
server:
  host: 127.0.0.1
  port: 0
mongo:
  uri: $testMongoUri
storage:
  file:
    path: ${storage.path}
''',
      environment: const {},
    ));
    addTearDown(server.stop);

    for (var i = 0; i < 100 && left.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(left.existsSync(), isFalse);
  });

  group('publish.uploadTimeout', () {
    test('fails a stalled write, retryably, and cleans up after it', () async {
      final store = _PausingStore(storage.path)
        ..reached = Completer<void>()
        ..resume = Completer<void>();
      final app = buildApp(
          packageStore: store,
          publish:
              const PublishConfig(uploadTimeout: Duration(milliseconds: 200)));

      final response =
          await app.handler(uploadRequest(pubspec('stalled'), _auth));

      final location = Uri.parse(response.headers['location']!);
      expect(
          location.queryParameters['error'], contains('publish.uploadTimeout'));
      expect(location.queryParameters['retryable'], 'true');
      expect(await reservations(), isEmpty);
      expect(await db.collection(packageCollection).findOne(), isNull);

      store.resume!.complete();
      for (var i = 0; i < 100 && stagedFiles().isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(stagedFiles(), isEmpty);
      expect(finalFile().existsSync(), isFalse);
    });

    test('renews the reservation once, halfway through', () async {
      final store = _PausingStore(storage.path)
        ..reached = Completer<void>()
        ..resume = Completer<void>();
      final app = buildApp(
          packageStore: store,
          publish:
              const PublishConfig(uploadTimeout: Duration(milliseconds: 600)));

      final running = upload(app, 'first');
      await store.reached!.future;
      final taken = (await reservations()).single['expiresAt'] as DateTime;

      await Future<void>.delayed(const Duration(milliseconds: 450));
      final renewed = (await reservations()).single['expiresAt'] as DateTime;
      expect(renewed.isAfter(taken), isTrue);

      store.resume!.complete();
      expect(await running, isNull);
    });

    test('a write that finishes in time is not renewed', () async {
      final store = _RenewalCountingStore(db);
      final app = buildApp(
          metaStore: store,
          publish:
              const PublishConfig(uploadTimeout: Duration(milliseconds: 200)));
      expect(await upload(app, 'first'), isNull);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(store.renewals, 0);
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
