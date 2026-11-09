import 'package:mongo_dart/mongo_dart.dart';
import 'package:test/test.dart';
import 'package:unpub/unpub.dart';

import 'utils.dart';

void main() {
  late Db db;
  late AccountStore store;
  late AccountService accounts;
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

  Migrator migrator() => Migrator(db, accounts, auth);

  test('creates a placeholder publisher for each uploader', () async {
    await addPackage('a', ['one@b.c', 'two@b.c']);
    await addPackage('b', ['two@b.c', 'three@b.c']);

    final outcomes = await migrator().run();
    expect(outcomes.single.status, MigrationStatus.applied);
    expect(outcomes.single.changes, hasLength(3));

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
    expect(outcomes.single.changes, isEmpty);
    final user = (await store.findUserByEmail('dev@b.c'))!;
    expect(user.role, Role.admin);
    expect(user.passwordHash, isNotNull);
  });

  test('reports and skips invalid entries', () async {
    await addPackage('a', ['not-an-email', 42, 'dev@b.c']);
    final outcomes = await migrator().run();
    expect(outcomes.single.changes,
        containsAll([contains('not-an-email'), contains('42')]));
    expect((await store.listUsers()).map((u) => u.email), ['dev@b.c']);
  });

  test('copes with packages that have no uploaders', () async {
    await addPackage('a', null);
    final outcomes = await migrator().run();
    expect(outcomes.single.status, MigrationStatus.applied);
    expect(await store.listUsers(), isEmpty);
  });

  test('copes with an empty database', () async {
    final outcomes = await migrator().run();
    expect(outcomes.single.status, MigrationStatus.applied);
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
    expect(second.single.status, MigrationStatus.alreadyApplied);
    expect(await store.findUserByEmail('later@b.c'), isNull);
    expect((await store.listUsers()), hasLength(1));
  });

  test('a dry run lists the changes and writes nothing', () async {
    await addPackage('a', ['dev@b.c']);
    final outcomes = await migrator().run(dryRun: true);
    expect(outcomes.single.status, MigrationStatus.wouldApply);
    expect(outcomes.single.changes, [contains('dev@b.c')]);
    expect(await store.listUsers(), isEmpty);
    expect(await db.collection(migrationCollection).findOne(), isNull);
    expect(await db.collection(auditCollection).findOne(), isNull);

    // The real run afterwards is unaffected by the dry run.
    final real = await migrator().run();
    expect(real.single.status, MigrationStatus.applied);
    expect(await store.findUserByEmail('dev@b.c'), isNotNull);
  });

  test('a dry run reports a step that already ran', () async {
    await migrator().run();
    final outcomes = await migrator().run(dryRun: true);
    expect(outcomes.single.status, MigrationStatus.alreadyApplied);
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
