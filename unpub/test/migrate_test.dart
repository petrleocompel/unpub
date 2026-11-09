import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mongo_dart/mongo_dart.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';
import 'package:unpub/unpub.dart';

import 'utils.dart';

void main() {
  late Db db;
  late AccountStore store;
  late AccountService accounts;
  late Directory archives;
  const auth = AuthConfig(bootstrapToken: null, bootstrapEmail: 'ops@b.c');

  Future<void> clean() async {
    for (final name in [
      packageCollection,
      userCollection,
      auditCollection,
      migrationCollection,
    ]) {
      await db.dropCollection(name);
    }
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
    archives = await Directory.systemTemp.createTemp('unpub-migrate-');
    addTearDown(() => archives.delete(recursive: true));
    store = AccountStore(db);
    await store.ensureIndexes();
    accounts = AccountService(store, audit: MongoAuditStore(db));
  });

  Future<void> addPackage(String name, List<Object?>? uploaders) =>
      db.collection(packageCollection).insertOne({
        'name': name,
        'versions': <Object>[],
        if (uploaders != null) 'uploaders': uploaders,
      });

  Migrator migrator() => Migrator(db, accounts, auth, FileStore(archives.path));

  test('creates a placeholder publisher for each uploader', () async {
    await addPackage('a', ['one@b.c', 'two@b.c']);
    await addPackage('b', ['two@b.c', 'three@b.c']);

    final outcomes = await migrator().run();
    expect(outcomes.first.status, MigrationStatus.applied);
    expect(outcomes.first.changes, hasLength(3));

    final users = await store.listUsers();
    expect(users.map((u) => u.email), ['one@b.c', 'three@b.c', 'two@b.c']);
    for (final user in users) {
      expect(user.role, Role.publisher);
      expect(user.passwordHash, isNull);
      expect(user.disabled, isFalse);
    }
    expect(users.first.displayName, 'one');
  });

  test('merges emails that differ in case', () async {
    await addPackage('a', ['Dev@B.c', 'dev@b.c']);
    await migrator().run();
    expect((await store.listUsers()).map((u) => u.email), ['dev@b.c']);
  });

  test('the bootstrap email becomes an admin when referenced', () async {
    await addPackage('a', ['OPS@b.c']);
    await migrator().run();
    expect((await store.findUserByEmail('ops@b.c'))!.role, Role.admin);
  });

  test('the bootstrap email is not created when unreferenced', () async {
    await addPackage('a', ['dev@b.c']);
    await migrator().run();
    expect(await store.findUserByEmail('ops@b.c'), isNull);
  });

  test('keeps existing users unchanged', () async {
    await accounts.createUser(
        email: 'dev@b.c', role: Role.admin, password: 'long-enough');
    await addPackage('a', ['dev@b.c']);
    final outcomes = await migrator().run();
    expect(outcomes.first.changes, isEmpty);
    final user = (await store.findUserByEmail('dev@b.c'))!;
    expect(user.role, Role.admin);
    expect(user.passwordHash, isNotNull);
  });

  test('reports and skips invalid entries', () async {
    await addPackage('a', ['not-an-email', 42, 'dev@b.c']);
    final outcomes = await migrator().run();
    expect(outcomes.first.changes,
        containsAll([contains('not-an-email'), contains('42')]));
    expect((await store.listUsers()).map((u) => u.email), ['dev@b.c']);
  });

  test('copes with packages that have no uploaders', () async {
    await addPackage('a', null);
    final outcomes = await migrator().run();
    expect(outcomes.first.status, MigrationStatus.applied);
    expect(await store.listUsers(), isEmpty);
  });

  test('copes with an empty database', () async {
    final outcomes = await migrator().run();
    expect(outcomes.first.status, MigrationStatus.applied);
  });

  test('is recorded and does not run twice', () async {
    await addPackage('a', ['dev@b.c']);
    await migrator().run();

    final record = await db
        .collection(migrationCollection)
        .findOne(where.eq('_id', '0001_users_from_uploaders'));
    expect(record!['appliedAt'], isA<DateTime>());

    await addPackage('b', ['later@b.c']);
    final second = await migrator().run();
    expect(second.first.status, MigrationStatus.alreadyApplied);
    expect(await store.findUserByEmail('later@b.c'), isNull);
    expect((await store.listUsers()), hasLength(1));
  });

  test('a dry run lists the changes and writes nothing', () async {
    await addPackage('a', ['dev@b.c']);
    final outcomes = await migrator().run(dryRun: true);
    expect(outcomes.first.status, MigrationStatus.wouldApply);
    expect(outcomes.first.changes, [contains('dev@b.c')]);
    expect(await store.listUsers(), isEmpty);
    expect(await db.collection(migrationCollection).findOne(), isNull);
    expect(await db.collection(auditCollection).findOne(), isNull);

    // The real run afterwards is unaffected by the dry run.
    final real = await migrator().run();
    expect(real.first.status, MigrationStatus.applied);
    expect(await store.findUserByEmail('dev@b.c'), isNotNull);
  });

  test('a dry run reports a step that already ran', () async {
    await migrator().run();
    final outcomes = await migrator().run(dryRun: true);
    expect(outcomes.first.status, MigrationStatus.alreadyApplied);
  });

  group('0002_version_sha256', () {
    Future<void> addVersions(String name, List<Map<String, Object>> versions) =>
        db.collection(packageCollection).insertOne({
          'name': name,
          'uploaders': <String>[],
          'versions': versions,
        });

    Future<Map<String, dynamic>> readVersion(String name, int index) async {
      final package = await db
          .collection(packageCollection)
          .findOne(where.eq('name', name));
      return package!['versions'][index] as Map<String, dynamic>;
    }

    File archive(String name, String version) =>
        File(path.join(archives.path, '$name-$version.tar.gz'));

    MigrationOutcome step(List<MigrationOutcome> outcomes) =>
        outcomes.singleWhere((o) => o.id == '0002_version_sha256');

    test('backfills the hash of each stored archive', () async {
      await addVersions('a', [
        {'version': '1.0.0'},
        {'version': '1.0.1+2'},
      ]);
      archive('a', '1.0.0').writeAsBytesSync([1, 2, 3]);
      archive('a', '1.0.1+2').writeAsBytesSync([4, 5, 6]);

      final outcome = step(await migrator().run());

      expect(outcome.status, MigrationStatus.applied);
      expect(outcome.changes, hasLength(2));
      expect((await readVersion('a', 0))['sha256'],
          sha256.convert([1, 2, 3]).toString());
      expect((await readVersion('a', 1))['sha256'],
          sha256.convert([4, 5, 6]).toString());
    });

    test('keeps a hash that is already stored', () async {
      await addVersions('a', [
        {'version': '1.0.0', 'sha256': 'existing'},
      ]);
      archive('a', '1.0.0').writeAsBytesSync([1]);

      final outcome = step(await migrator().run());

      expect(outcome.changes, isEmpty);
      expect((await readVersion('a', 0))['sha256'], 'existing');
    });

    test('skips a missing archive with a warning and finishes', () async {
      await addVersions('a', [
        {'version': '1.0.0'},
        {'version': '2.0.0'},
      ]);
      archive('a', '2.0.0').writeAsBytesSync([1]);

      final outcome = step(await migrator().run());

      expect(outcome.status, MigrationStatus.applied);
      expect(outcome.changes,
          containsAll(['skip a@1.0.0: archive missing', 'hash a@2.0.0']));
      expect((await readVersion('a', 0)).containsKey('sha256'), isFalse);
      expect((await readVersion('a', 1))['sha256'], isNotNull);
    });

    test('is idempotent', () async {
      await addVersions('a', [
        {'version': '1.0.0'},
      ]);
      archive('a', '1.0.0').writeAsBytesSync([1]);
      await migrator().run();
      final first = await readVersion('a', 0);

      archive('a', '1.0.0').writeAsBytesSync([9]);
      final outcome = step(await migrator().run());

      expect(outcome.status, MigrationStatus.alreadyApplied);
      expect(await readVersion('a', 0), first);
    });

    group('--rerun', () {
      final restored = [1, 2, 3];

      Future<void> addSkippedVersion() async {
        await db.collection(packageCollection).insertOne({
          'name': 'pkg',
          'versions': [
            {'version': '1.0.0'},
          ],
        });
        await migrator().run();
      }

      Future<Object?> storedHash() async => (await db
          .collection(packageCollection)
          .findOne(where.eq('name', 'pkg')))!['versions'][0]['sha256'];

      void restoreArchive() =>
          File(path.join(archives.path, 'pkg-1.0.0.tar.gz'))
            ..writeAsBytesSync(restored);

      test('a normal run does not come back to a skipped version', () async {
        await addSkippedVersion();
        restoreArchive();

        await migrator().run();

        expect(await storedHash(), isNull);
      });

      test('hashes a version that was skipped', () async {
        await addSkippedVersion();
        restoreArchive();

        final outcomes = await migrator().run(rerun: '0002');

        expect(outcomes.single.id, '0002_version_sha256');
        expect(outcomes.single.status, MigrationStatus.applied);
        expect(outcomes.single.changes, ['hash pkg@1.0.0']);
        expect(await storedHash(), sha256.convert(restored).toString());
        final record = await db
            .collection(migrationCollection)
            .findOne(where.eq('_id', '0002_version_sha256'));
        expect(record!['lastRerunAt'], isA<DateTime>());
      });

      test('leaves other steps alone', () async {
        await addSkippedVersion();
        await db
            .collection(migrationCollection)
            .deleteOne(where.eq('_id', '0001_users_from_uploaders'));

        final outcomes = await migrator().run(rerun: '0002');

        expect(outcomes, hasLength(1));
        expect(
            await db
                .collection(migrationCollection)
                .findOne(where.eq('_id', '0001_users_from_uploaders')),
            isNull);
      });

      test('a dry run writes nothing', () async {
        await addSkippedVersion();
        restoreArchive();

        final outcomes = await migrator().run(rerun: '0002', dryRun: true);

        expect(outcomes.single.status, MigrationStatus.wouldApply);
        expect(outcomes.single.changes, ['hash pkg@1.0.0']);
        expect(await storedHash(), isNull);
      });

      test('still reports an archive that is missing', () async {
        await addSkippedVersion();
        final outcomes = await migrator().run(rerun: '0002');
        expect(outcomes.single.changes, ['skip pkg@1.0.0: archive missing']);
      });

      test('refuses a step that cannot be run again', () async {
        expect(() => migrator().run(rerun: '0001'), throwsArgumentError);
      });
    });

    test('a dry run lists what would be hashed and writes nothing', () async {
      await addVersions('a', [
        {'version': '1.0.0'},
      ]);
      archive('a', '1.0.0').writeAsBytesSync([1]);

      final outcome = step(await migrator().run(dryRun: true));

      expect(outcome.status, MigrationStatus.wouldApply);
      expect(outcome.changes, ['hash a@1.0.0']);
      expect((await readVersion('a', 0)).containsKey('sha256'), isFalse);
      expect(
          await db
              .collection(migrationCollection)
              .findOne(where.eq('_id', '0002_version_sha256')),
          isNull);
    });
  });

  test('records the creation as a system action', () async {
    await addPackage('a', ['dev@b.c']);
    await migrator().run();
    final event = await db.collection(auditCollection).findOne();
    expect(event!['actor'], 'system');
    expect(event['action'], 'user.created');
    expect(event['target'], 'dev@b.c');
    expect(event['details']['migration'], '0001_users_from_uploaders');
  });
}
