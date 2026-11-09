import 'dart:async';

import 'package:mongo_dart/mongo_dart.dart';
import 'package:test/test.dart';
import 'package:unpub/unpub.dart';

import 'utils.dart';

const _digest = 'a-digest';

void main() {
  late Db db;

  Future<Map<String, dynamic>?> stored() =>
      db.collection(objectLocksCollection).findOne(where.eq('_id', _digest));

  setUpAll(() async {
    db = Db(testMongoUri);
    await db.open();
  });

  tearDownAll(() async {
    await db.dropCollection(objectLocksCollection);
    await db.close();
  });

  setUp(() async {
    await db.dropCollection(objectLocksCollection);
    await MongoStore(db).ensureIndexes();
  });

  group('a Mongo object lock', () {
    late MongoObjectLocks locks;

    setUp(() => locks = MongoObjectLocks(db));

    test('is exclusive until released', () async {
      final held = await locks.tryLock(_digest);
      expect(held, isNotNull);
      expect(await locks.tryLock(_digest), isNull);

      await held!.release();

      expect(await stored(), isNull);
      final next = await locks.tryLock(_digest);
      expect(next, isNotNull);
      await next!.release();
    });

    test('of one digest does not affect another', () async {
      final held = await locks.tryLock(_digest);
      final other = await locks.tryLock('another-digest');
      expect(other, isNotNull);
      await held!.release();
      await other!.release();
    });

    test('of two concurrent attempts, only one wins', () async {
      final attempts =
          await Future.wait([for (var i = 0; i < 16; i++) locks.tryLock('d')]);
      final winners = attempts.whereType<ObjectLock>().toList();
      expect(winners, hasLength(1));
      await winners.single.release();
    });

    test('lasts two minutes', () async {
      final held = await locks.tryLock(_digest);
      final expiresAt = (await stored())!['expiresAt'] as DateTime;
      expect(expiresAt.difference(DateTime.now()).inSeconds,
          inInclusiveRange(100, 130));
      await held!.release();
    });

    test('left by a crashed holder expires, and the next acquirer proceeds',
        () async {
      final short =
          MongoObjectLocks(db, lease: const Duration(milliseconds: 300));
      expect(await short.tryAcquire(_digest, 'crashed'), isTrue);
      expect(await short.tryLock(_digest), isNull);

      await Future<void>.delayed(const Duration(milliseconds: 400));

      final next = await short.tryLock(_digest);
      expect(next, isNotNull);
      expect((await stored())!['owner'], isNot('crashed'));
      await next!.release();
    });

    test('with an expired document is taken over', () async {
      await db.collection(objectLocksCollection).insertOne({
        '_id': _digest,
        'owner': 'crashed',
        'expiresAt': DateTime.now().subtract(const Duration(minutes: 1)),
      });
      final held = await locks.tryLock(_digest);
      expect(held, isNotNull);
      await held!.release();
    });

    test('with no expiry is taken over', () async {
      await db
          .collection(objectLocksCollection)
          .insertOne({'_id': _digest, 'owner': 'odd'});
      final held = await locks.tryLock(_digest);
      expect(held, isNotNull);
      await held!.release();
    });

    test('is renewed while it is held', () async {
      final short =
          MongoObjectLocks(db, lease: const Duration(milliseconds: 300));
      final held = await short.tryLock(_digest);

      await Future<void>.delayed(const Duration(milliseconds: 700));

      expect(await short.tryLock(_digest), isNull);
      await held!.release();
      final next = await short.tryLock(_digest);
      expect(next, isNotNull);
      await next!.release();
    });

    test('can only be renewed and released by its holder', () async {
      expect(await locks.tryAcquire(_digest, 'mine'), isTrue);
      final before = await stored();

      expect(await locks.renew(_digest, 'theirs'), isFalse);
      await locks.release(_digest, 'theirs');
      expect(await stored(), before);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await locks.renew(_digest, 'mine'), isTrue);
      expect(
          ((await stored())!['expiresAt'] as DateTime)
              .isAfter(before!['expiresAt'] as DateTime),
          isTrue);

      await locks.release(_digest, 'mine');
      expect(await stored(), isNull);
      expect(await locks.renew(_digest, 'mine'), isFalse);
    });

    test('confirm says when the lock is gone', () async {
      final held = await locks.tryLock(_digest);
      expect(await held!.confirm(), isTrue);

      await db.collection(objectLocksCollection).deleteMany({});

      expect(await held.confirm(), isFalse);
      await held.release();
      expect(await held.confirm(), isFalse);
    });

    test('waits for a holder within the timeout', () async {
      final held = await locks.tryLock(_digest);
      final waiting = locks.lock(_digest, timeout: const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await held!.release();

      final acquired = await waiting;
      expect(acquired, isNotNull);
      await acquired!.release();
    });

    test('gives up after the timeout', () async {
      final held = await locks.tryLock(_digest);
      final waited = Stopwatch()..start();

      final acquired =
          await locks.lock(_digest, timeout: const Duration(milliseconds: 200));

      expect(acquired, isNull);
      expect(waited.elapsedMilliseconds, greaterThanOrEqualTo(200));
      await held!.release();
    });

    test('has a TTL index, so that a crash leaves nothing for good', () async {
      final indexes = await db.collection(objectLocksCollection).getIndexes();
      expect(
          indexes.singleWhere(
              (i) => i['name'] == 'expires_at_ttl')['expireAfterSeconds'],
          0);
    });
  });

  group('a local object lock', () {
    test('is exclusive until released', () async {
      final locks = LocalObjectLocks();
      final held = await locks.tryLock(_digest);
      expect(await locks.tryLock(_digest), isNull);
      await held!.release();
      expect(await locks.tryLock(_digest), isNotNull);
    });

    test('can only be released by its holder', () async {
      final locks = LocalObjectLocks();
      expect(await locks.tryAcquire(_digest, 'mine'), isTrue);
      expect(await locks.renew(_digest, 'theirs'), isFalse);
      await locks.release(_digest, 'theirs');
      expect(await locks.tryAcquire(_digest, 'theirs'), isFalse);
    });
  });

  test('a failed release is logged and does not throw', () async {
    final held = await _FailingRelease().tryLock(_digest);
    await held!.release();
  });
}

class _FailingRelease extends LocalObjectLocks {
  @override
  Future<void> release(String digest, String owner) =>
      throw StateError('connection lost');
}
