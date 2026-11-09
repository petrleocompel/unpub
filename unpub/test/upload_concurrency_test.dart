import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:async/async.dart';
import 'package:minio/minio.dart';
import 'package:mongo_dart/mongo_dart.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';
import 'package:unpub/unpub.dart';

import 'utils.dart';

const _name = 'contested';
const _token = 'token';
const _auth = {'authorization': 'Bearer $_token'};

final _s3Endpoint = Platform.environment['UNPUB_TEST_S3_ENDPOINT'];
const _s3Bucket = 'dart-pub-test';

Minio _createMinio() {
  final endpoint = Uri.parse('http://$_s3Endpoint');
  return Minio(
    endPoint: endpoint.host,
    port: endpoint.port,
    useSSL: false,
    region: 'us-east-1',
    accessKey:
        Platform.environment['UNPUB_TEST_S3_ACCESS_KEY'] ?? 'rustfsadmin',
    secretKey:
        Platform.environment['UNPUB_TEST_S3_SECRET_KEY'] ?? 'rustfsadmin',
  );
}

/// A [FileStore] that can stop in the middle of storing an archive.
class _PausingStore extends FileStore {
  Completer<void>? reached;
  Completer<void>? resume;
  final finished = Completer<void>();
  Object? failure;

  _PausingStore(super.baseDir);

  @override
  Future<void> storeObject(
      String name, String version, String digest, List<int> content) async {
    if (reached?.isCompleted == false) reached!.complete();
    await resume?.future;
    final error = failure;
    if (error != null) throw error;
    await super.storeObject(name, version, digest, content);
    if (!finished.isCompleted) finished.complete();
  }
}

/// Wraps any store, and stops once right after writing an object, so that a
/// publish can be stalled past its reservation with its archive already
/// written.
class _StallingStore extends PackageStore {
  final PackageStore inner;
  final reached = Completer<void>();
  final resume = Completer<void>();

  _StallingStore(this.inner);

  @override
  Future<void> upload(String name, String version, List<int> content) =>
      inner.upload(name, version, content);

  @override
  Future<void> storeObject(
      String name, String version, String digest, List<int> content) async {
    await inner.storeObject(name, version, digest, content);
    if (!reached.isCompleted) {
      reached.complete();
      await resume.future;
    }
  }

  @override
  Future<bool> objectExists(String name, String version, String digest) =>
      inner.objectExists(name, version, digest);

  @override
  Stream<List<int>> downloadObject(
          String name, String version, String digest) =>
      inner.downloadObject(name, version, digest);

  @override
  Future<void> deleteObject(String name, String version, String digest) =>
      inner.deleteObject(name, version, digest);

  @override
  Future<bool> exists(String name, String version) =>
      inner.exists(name, version);

  @override
  Stream<List<int>> download(String name, String version) =>
      inner.download(name, version);
}

/// Fails to write the version, with the write either lost or applied.
class _FailingMetaStore extends MongoStore {
  final bool applied;

  _FailingMetaStore(super.db, {required this.applied});

  @override
  Future<void> addVersion(String name, UnpubVersion version) async {
    if (applied) await super.addVersion(name, version);
    throw 'connection lost';
  }
}

/// Removes the object while the version is being added, as a reclamation
/// that decided just before the metadata was written would.
class _RemovingMetaStore extends MongoStore {
  final PackageStore store;

  _RemovingMetaStore(super.db, this.store);

  @override
  Future<void> addVersion(String name, UnpubVersion version) async {
    await store.deleteObject(name, version.version, version.sha256!);
    await super.addVersion(name, version);
  }
}

/// A [MongoStore] that always loses the race for a new version.
class _LosingMetaStore extends MongoStore {
  _LosingMetaStore(super.db);

  @override
  Future<void> addVersion(String name, UnpubVersion version) async =>
      throw VersionExistsException(name, version.version);
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

  File objectFile(String digest, [String version = '1.0.0']) =>
      File('${storage.path}/$_name/$_name-$version-$digest.tar.gz');

  /// The hash of the stored archive must be the one recorded for the version,
  /// and [description] the content of the upload that won.
  Future<void> expectConsistent(String description) async {
    final stored = await storedVersion();
    expect(stored['pubspec']['description'], description);
    final bytes = objectFile(stored['sha256'] as String).readAsBytesSync();
    expect(crypto.sha256.convert(bytes).toString(), stored['sha256']);
  }

  /// What a client downloads for the version must hash to its validator, and
  /// to the hash in the metadata.
  Future<void> expectServedConsistent(App app) async {
    final stored = await storedVersion();
    final response = await app.handler(shelf.Request('GET',
        Uri.parse('http://localhost/packages/$_name/versions/1.0.0.tar.gz')));
    expect(response.statusCode, HttpStatus.ok);
    final digest = crypto.sha256
        .convert(await collectBytes(response.read().map((c) => c)))
        .toString();
    expect(digest, stored['sha256']);
    expect(response.headers['etag'], '"$digest"');
  }

  Future<List<Map<String, dynamic>>> reservations() => db
      .collection(uploadReservationsCollection)
      .find(where.eq('name', _name))
      .toList();

  File legacyFile() => File('${storage.path}/$_name-1.0.0.tar.gz');

  List<File> objects() {
    final directory = Directory('${storage.path}/$_name');
    return directory.existsSync()
        ? directory.listSync().whereType<File>().toList()
        : const [];
  }

  List<FileSystemEntity> temporaries() {
    final directory = Directory('${storage.path}/.unpub-tmp');
    return directory.existsSync() ? directory.listSync() : const [];
  }

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

  group('adding a version', () {
    UnpubVersion entry(String version, String hash) => UnpubVersion(
          version,
          {'name': _name, 'version': version},
          'name: $_name',
          'dev@b.c',
          null,
          null,
          DateTime.now(),
          sha256: hash,
        );

    Future<List<Map<String, dynamic>>> packageDocuments() =>
        db.collection(packageCollection).find(where.eq('name', _name)).toList();

    Future<List<Object?>> addAll(List<UnpubVersion> versions) async {
      final store = MongoStore(db);
      return Future.wait([
        for (final item in versions)
          store
              .addVersion(_name, item)
              .then<Object?>((_) => null, onError: (Object error) => error),
      ]);
    }

    test('two concurrent first publishes leave one entry', () async {
      final results = await addAll([entry('1.0.0', 'a'), entry('1.0.0', 'b')]);

      expect(results.whereType<VersionExistsException>(), hasLength(1));
      expect(results.where((error) => error == null), hasLength(1));
      final documents = await packageDocuments();
      expect(documents, hasLength(1));
      expect(documents.single['versions'], hasLength(1));
      expect(documents.single['uploaders'], ['dev@b.c']);
      expect(documents.single['private'], isTrue);
      expect(documents.single['download'], 0);
    });

    test('many concurrent first publishes leave one entry', () async {
      final results = await addAll(
          [for (var i = 0; i < 16; i++) entry('1.0.0', 'hash $i')]);

      expect(results.where((error) => error == null), hasLength(1));
      expect(results.whereType<VersionExistsException>(), hasLength(15));
      final documents = await packageDocuments();
      expect(documents, hasLength(1));
      expect(documents.single['versions'], hasLength(1));
    });

    test('concurrent first publishes of different versions all land', () async {
      final results = await addAll([
        for (var i = 0; i < 8; i++) entry('1.0.$i', 'hash $i'),
      ]);

      expect(results.whereType<Object>(), isEmpty);
      final documents = await packageDocuments();
      expect(documents, hasLength(1));
      expect(documents.single['versions'], hasLength(8));
    });

    test('two concurrent adds to an existing package leave one entry',
        () async {
      await MongoStore(db).addVersion(_name, entry('1.0.0', 'first'));

      final results = await addAll([entry('2.0.0', 'a'), entry('2.0.0', 'b')]);

      expect(results.where((error) => error == null), hasLength(1));
      expect(results.whereType<VersionExistsException>(), hasLength(1));
      final versions = (await packageDocuments()).single['versions'] as List;
      expect(
          versions.where((item) => item['version'] == '2.0.0'), hasLength(1));
    });

    test('adding a version that exists changes nothing', () async {
      final store = MongoStore(db);
      await store.addVersion(_name, entry('1.0.0', 'first'));
      await expectLater(store.addVersion(_name, entry('1.0.0', 'second')),
          throwsA(isA<VersionExistsException>()));
      expect((await storedVersion())['sha256'], 'first');
    });
  });

  group('the unique index on package names', () {
    test('exists after startup', () async {
      final indexes = await db.collection(packageCollection).getIndexes();
      expect(indexes.singleWhere((i) => i['name'] == 'name_unique')['unique'],
          isTrue);
    });

    test('is safe to create twice', () async {
      await MongoStore(db).ensureIndexes();
      await MongoStore(db).ensureIndexes();
    });

    test('refuses to start with a duplicate, and names it', () async {
      await db.dropCollection(packageCollection);
      await db.collection(packageCollection).insertMany([
        {'name': 'twice', 'versions': []},
        {'name': 'twice', 'versions': []},
        {'name': 'once', 'versions': []},
      ]);

      await expectLater(
          MongoStore(db).ensureIndexes(),
          throwsA(isA<StateError>().having((e) => e.message, 'message',
              allOf(contains('twice'), isNot(contains('once'))))));
    });
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
      expect(objects(), isEmpty);
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

  group('digest-addressed objects', () {
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
      final winnerBytes = objects().single.readAsBytesSync();

      store.resume!.complete();

      expect(await stalled, contains('already exists'));
      expect(objects().single.readAsBytesSync(), winnerBytes);
      await expectConsistent('winner');
      expect(temporaries(), isEmpty);
    });

    test('nothing is published until the metadata is written', () async {
      final store = _PausingStore(storage.path)
        ..reached = Completer<void>()
        ..resume = Completer<void>();
      final running = upload(buildApp(packageStore: store), 'first');
      await store.reached!.future;
      expect(await db.collection(packageCollection).findOne(), isNull);

      store.resume!.complete();

      expect(await running, isNull);
      expect(objects(), hasLength(1));
      expect(legacyFile().existsSync(), isFalse);
      await expectConsistent('first');
    });

    test('losing the metadata write deletes the object', () async {
      final error =
          await upload(buildApp(metaStore: _LosingMetaStore(db)), 'first');

      expect(error, contains('already exists'));
      expect(objects(), isEmpty);
      expect(temporaries(), isEmpty);
    });

    test('a failed metadata write deletes the object', () async {
      final error = await upload(
          buildApp(metaStore: _FailingMetaStore(db, applied: false)), 'first');

      expect(error, contains('connection lost'));
      expect(objects(), isEmpty);
    });

    test('an object the metadata does refer to is kept', () async {
      final error = await upload(
          buildApp(metaStore: _FailingMetaStore(db, applied: true)), 'first');

      expect(error, contains('connection lost'));
      expect(objects(), hasLength(1));
      await expectConsistent('first');
    });

    test('an identical loser leaves the object of the winner', () async {
      final store = _PausingStore(storage.path)
        ..reached = Completer<void>()
        ..resume = Completer<void>();
      final stalled = upload(buildApp(packageStore: store), 'same');
      await store.reached!.future;
      await db
          .collection(uploadReservationsCollection)
          .deleteMany(where.eq('name', _name));
      expect(await upload(buildApp(), 'same'), isNull);

      store.resume!.complete();

      expect(await stalled, contains('already exists'));
      await expectConsistent('same');
    });

    test('an object removed during the publish is put back', () async {
      final store = FileStore(storage.path);
      expect(
          await upload(
              buildApp(
                  packageStore: store,
                  metaStore: _RemovingMetaStore(db, store)),
              'first'),
          isNull);
      await expectConsistent('first');
    });

    test('a legacy file neither blocks a publish nor is served over it',
        () async {
      legacyFile().writeAsStringSync('left behind');

      final app = buildApp();
      expect(await upload(app, 'first'), isNull);

      expect(legacyFile().readAsStringSync(), 'left behind');
      await expectConsistent('first');
      await expectServedConsistent(app);
    });

    test('a failing write leaves nothing', () async {
      final store = _PausingStore(storage.path)..failure = 'disk full';
      expect(await upload(buildApp(packageStore: store), 'first'),
          contains('disk full'));
      expect(objects(), isEmpty);
      expect(temporaries(), isEmpty);
    });

    test('replacing a version adds an object and moves the pointer', () async {
      final app =
          buildApp(publish: const PublishConfig(requireVersionBump: false));
      expect(await upload(app, 'first'), isNull);
      final first = (await storedVersion())['sha256'] as String;
      expect(await upload(app, 'second'), isNull);
      final second = (await storedVersion())['sha256'] as String;

      expect(second, isNot(first));
      expect(objectFile(first).existsSync(), isTrue);
      await expectConsistent('second');
      await expectServedConsistent(app);
      expect(temporaries(), isEmpty);
    });

    test('replacing a version without a hash is allowed', () async {
      final app =
          buildApp(publish: const PublishConfig(requireVersionBump: false));
      expect(await upload(app, 'first'), isNull);
      await db.collection(packageCollection).updateOne(
          where.eq('name', _name), modify.unset(r'versions.0.sha256'));

      expect(await upload(app, 'second'), isNull);
      await expectConsistent('second');
    });

    group('replacing, in the metadata store', () {
      UnpubVersion entry(String hash) => UnpubVersion(
            '1.0.0',
            {'name': _name, 'version': '1.0.0'},
            'name: $_name',
            'dev@b.c',
            null,
            null,
            DateTime.now(),
            sha256: hash,
          );

      setUp(() => MongoStore(db).addVersion(_name, entry('original')));

      test('applies when the hash is the expected one', () async {
        expect(
            await MongoStore(db).replaceVersion(_name, entry('new'),
                expectedSha256: 'original'),
            isTrue);
        expect((await storedVersion())['sha256'], 'new');
      });

      test('changes nothing when the hash has moved on', () async {
        expect(
            await MongoStore(db)
                .replaceVersion(_name, entry('new'), expectedSha256: 'stale'),
            isFalse);
        expect((await storedVersion())['sha256'], 'original');
      });

      test('of two with the same expectation only one wins', () async {
        final store = MongoStore(db);
        final results = await Future.wait([
          store.replaceVersion(_name, entry('a'), expectedSha256: 'original'),
          store.replaceVersion(_name, entry('b'), expectedSha256: 'original'),
        ]);
        expect(results.where((won) => won), hasLength(1));
      });
    });
  });

  group('reclaiming orphans against the metadata', () {
    final reclaimAt = DateTime.now().add(const Duration(hours: 2));

    TemporaryReclaimer reclaimer() =>
        TemporaryReclaimer(FileStore(storage.path),
            references: MongoArchiveReferences(db));

    test('removes what a replacement left behind, and only that', () async {
      final app =
          buildApp(publish: const PublishConfig(requireVersionBump: false));
      expect(await upload(app, 'first'), isNull);
      final first = (await storedVersion())['sha256'] as String;
      expect(await upload(app, 'second'), isNull);
      final second = (await storedVersion())['sha256'] as String;

      expect(await reclaimer().reclaimOrphans(now: reclaimAt), 1);

      expect(objectFile(first).existsSync(), isFalse);
      expect(objectFile(second).existsSync(), isTrue);
      await expectServedConsistent(app);
    });

    test('a fresh orphan is kept', () async {
      final app =
          buildApp(publish: const PublishConfig(requireVersionBump: false));
      expect(await upload(app, 'first'), isNull);
      final first = (await storedVersion())['sha256'] as String;
      expect(await upload(app, 'second'), isNull);

      expect(await reclaimer().reclaimOrphans(), 0);
      expect(objectFile(first).existsSync(), isTrue);
    });

    test('an upstream_archives record keeps its object', () async {
      final bytes = [1, 2, 3];
      final digest = crypto.sha256.convert(bytes).toString();
      final store = FileStore(storage.path);
      final temporary = await store.upstreamTemporaryFile('proxied', '1.0.0');
      await temporary.writeAsBytes(bytes);
      await store.commitUpstream('proxied', '1.0.0', digest, temporary, 3);
      addTearDown(() => db.dropCollection(upstreamArchivesCollection));

      await MongoUpstreamCacheStore(db).writeArchive(UpstreamArchiveRecord(
        name: 'proxied',
        version: '1.0.0',
        sha256: digest,
        bytes: 3,
        fetchedAt: DateTime.now(),
        verified: true,
      ));
      expect(await reclaimer().reclaimOrphans(now: reclaimAt), 0);
      expect(await store.upstreamCached('proxied', '1.0.0', digest), isTrue);

      await db.dropCollection(upstreamArchivesCollection);
      expect(await reclaimer().reclaimOrphans(now: reclaimAt), 1);
      expect(await store.upstreamCached('proxied', '1.0.0', digest), isFalse);
    });
  });

  for (final backend in ['file', 's3']) {
    group('a publisher stalled past its reservation, on $backend', () {
      late PackageStore store;

      setUpAll(() async {
        if (backend == 's3' && _s3Endpoint != null) {
          final minio = _createMinio();
          if (!await minio.bucketExists(_s3Bucket)) {
            await minio.makeBucket(_s3Bucket);
          }
        }
      });

      setUp(() {
        store = backend == 'file'
            ? FileStore(storage.path)
            : S3Store(_s3Bucket, minio: _createMinio());
      });

      Future<void> expire() => db
          .collection(uploadReservationsCollection)
          .deleteMany(where.eq('name', _name));

      test('a first publish loses and the winner is served', () async {
        final stalling = _StallingStore(store);
        final app = buildApp(packageStore: store);
        final stalled = upload(buildApp(packageStore: stalling), 'stalled');
        await stalling.reached.future;
        await expire();

        expect(await upload(app, 'winner'), isNull);
        final winner = (await storedVersion())['sha256'] as String;
        await expectServedConsistent(app);

        stalling.resume.complete();

        expect(await stalled, contains('already exists'));
        expect((await storedVersion())['sha256'], winner);
        expect((await storedVersion())['pubspec']['description'], 'winner');
        await expectServedConsistent(app);
      });

      test('a replacement loses and the winner is served', () async {
        const publish = PublishConfig(requireVersionBump: false);
        final app = buildApp(packageStore: store, publish: publish);
        expect(await upload(app, 'original'), isNull);

        final stalling = _StallingStore(store);
        final stalled = upload(
            buildApp(packageStore: stalling, publish: publish), 'stalled');
        await stalling.reached.future;
        await expire();

        expect(await upload(app, 'winner'), isNull);
        final winner = (await storedVersion())['sha256'] as String;
        await expectServedConsistent(app);

        stalling.resume.complete();

        expect(await stalled, contains('being published by another request'));
        expect((await storedVersion())['sha256'], winner);
        expect((await storedVersion())['pubspec']['description'], 'winner');
        await expectServedConsistent(app);
      });
    },
        skip: backend == 's3' && _s3Endpoint == null
            ? 'UNPUB_TEST_S3_ENDPOINT is not set'
            : false);
  }

  test('the server clears crash leftovers when it starts', () async {
    final left = File('${storage.path}/.unpub-tmp/crashed.part')
      ..createSync(recursive: true)
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
      await store.finished.future;
      for (var i = 0; i < 100 && objects().isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(objects(), isEmpty);
      expect(temporaries(), isEmpty);
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
