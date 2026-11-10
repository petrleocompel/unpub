import 'dart:async';

import 'package:logging/logging.dart';
import 'package:mongo_dart/mongo_dart.dart';

import '../logging.dart';

final objectLocksCollection = 'object_locks';

/// How long an object lock lasts without being renewed, and so how long a
/// holder that crashed can keep others waiting.
const objectLockLease = Duration(minutes: 2);

const _firstPollDelay = Duration(milliseconds: 50);
const _longestPollDelay = Duration(seconds: 1);

const _duplicateKeyCode = 11000;

final _log = Logger('unpub.locks');

/// One lock per digest, held by everything that writes or deletes the object
/// with that digest, so that deleting an object nothing refers to cannot race
/// the publish that is about to refer to it.
///
/// A holder renews its lease while it works. If it crashes the lock expires
/// after [lease], which is why reclamation also leaves alone anything younger
/// than an hour.
abstract class ObjectLocks {
  Duration get lease => objectLockLease;

  /// Claims [digest] for [owner], and returns whether that worked.
  Future<bool> tryAcquire(String digest, String owner);

  /// Extends the claim of [owner], and returns whether it still held it.
  Future<bool> renew(String digest, String owner);

  /// Gives up the claim of [owner], if it still has one.
  Future<void> release(String digest, String owner);

  /// Takes the lock of [digest], or answers null if someone else has it.
  Future<ObjectLock?> tryLock(String digest) async {
    final owner = ObjectId().oid;
    if (!await tryAcquire(digest, owner)) return null;
    return ObjectLock._(this, digest, owner);
  }

  /// Takes the lock of [digest], waiting up to [timeout], or answers null if
  /// it stayed busy for that long.
  Future<ObjectLock?> lock(String digest, {required Duration timeout}) async {
    final waited = Stopwatch()..start();
    var delay = _firstPollDelay;
    while (true) {
      final held = await tryLock(digest);
      if (held != null) return held;
      final left = timeout - waited.elapsed;
      if (left <= Duration.zero) return null;
      await Future<void>.delayed(delay < left ? delay : left);
      delay = delay * 2 < _longestPollDelay ? delay * 2 : _longestPollDelay;
    }
  }
}

/// A held lock, renewed in the background until it is [release]d.
class ObjectLock {
  final ObjectLocks _locks;
  final String digest;
  final String _owner;
  late final Timer _renewal;
  bool _released = false;

  ObjectLock._(this._locks, this.digest, this._owner) {
    _renewal = Timer.periodic(_locks.lease ~/ 3, (_) => unawaited(confirm()));
  }

  /// Extends the lease, and returns whether the lock is still held. Check this
  /// right before something the lock protects, because a lease can run out
  /// during a stall that keeps the renewals from running. A failure to ask
  /// counts as not held.
  Future<bool> confirm() async {
    if (_released) return false;
    try {
      if (await _locks.renew(digest, _owner)) return true;
      _log.warning(LogEvent('an object lock was lost', {'digest': digest}));
    } catch (error, stackTrace) {
      _log.warning(
          LogEvent('failed to renew an object lock', {'digest': digest}),
          error,
          stackTrace);
    }
    return false;
  }

  /// Gives the lock up. A lock that cannot be given up expires by itself, so
  /// a failure is only logged. Repeating this does nothing.
  Future<void> release() async {
    if (_released) return;
    _released = true;
    _renewal.cancel();
    try {
      await _locks.release(digest, _owner);
    } catch (error, stackTrace) {
      _log.warning(
          LogEvent('failed to release an object lock', {'digest': digest}),
          error,
          stackTrace);
    }
  }
}

/// Locks within this process, for a metadata store that is not shared between
/// instances. Nothing has to expire, because the locks end with the process.
class LocalObjectLocks extends ObjectLocks {
  final _holders = <String, String>{};

  @override
  Future<bool> tryAcquire(String digest, String owner) async =>
      _holders.putIfAbsent(digest, () => owner) == owner;

  @override
  Future<bool> renew(String digest, String owner) async =>
      _holders[digest] == owner;

  @override
  Future<void> release(String digest, String owner) async {
    if (_holders[digest] == owner) _holders.remove(digest);
  }
}

/// Keeps locks in the `object_locks` collection, one document per digest.
///
/// Every expiry is decided on the clock of the database, so that instances
/// whose clocks disagree still agree on when a lock has run out.
class MongoObjectLocks extends ObjectLocks {
  final Db db;

  @override
  final Duration lease;

  MongoObjectLocks(this.db, {this.lease = objectLockLease});

  DbCollection get _locks => db.collection(objectLocksCollection);

  /// `$$NOW` needs MongoDB 4.2, and 3.6 is still supported.
  Future<DateTime> _databaseNow() async {
    final reply = await db.runCommand({'isMaster': 1});
    final now = reply['localTime'];
    if (now is! DateTime) {
      throw StateError('cannot read the clock of the database');
    }
    return now;
  }

  @override
  Future<bool> tryAcquire(String digest, String owner) async {
    final now = await _databaseNow();
    final result = await _locks.modernFindAndModify(
      query: {
        '_id': digest,
        r'$or': [
          {
            'expiresAt': {r'$lt': now},
          },
          {
            'expiresAt': {r'$exists': false},
          },
        ],
      },
      update: {
        r'$set': {'owner': owner, 'expiresAt': now.add(lease)},
      },
      upsert: true,
      returnNew: true,
    );
    // The filter did not match a live lock, so the upsert tried to create a
    // second document for the digest.
    if (result.code == _duplicateKeyCode) return false;
    if (result.failure) {
      throw StateError('cannot take an object lock: ${result.errmsg}');
    }
    return result.value?['owner'] == owner;
  }

  @override
  Future<bool> renew(String digest, String owner) async {
    final now = await _databaseNow();
    final result = await _locks.updateOne(
        where.eq('_id', digest).eq('owner', owner),
        modify.set('expiresAt', now.add(lease)));
    return result.nMatched == 1;
  }

  @override
  Future<void> release(String digest, String owner) async {
    await _locks.deleteOne(where.eq('_id', digest).eq('owner', owner));
  }
}
