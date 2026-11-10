import 'dart:async';

import 'package:crypto/crypto.dart' show sha256;
import 'package:logging/logging.dart';

import '../logging.dart';
import 'archive_references.dart';
import 'package_store.dart';

final _log = Logger('unpub.reclaim');

/// Deletes what a crash or a lost race left in a store, at startup and then
/// periodically: temporary files, and with [references] also digest-addressed
/// objects that nothing points to any more.
class TemporaryReclaimer {
  final PackageStore store;
  final ArchiveReferences? references;
  final Duration interval;
  Timer? _timer;
  bool _running = false;

  TemporaryReclaimer(this.store,
      {this.references, this.interval = const Duration(hours: 1)});

  void start() {
    unawaited(run());
    _timer = Timer.periodic(interval, (_) => unawaited(run()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Returns how many files and objects were deleted. A failure is only
  /// logged, because the next run tries again.
  Future<int> run() async {
    if (_running) return 0;
    _running = true;
    try {
      return await _reclaim('temporary files', store.reclaimTemporary) +
          await _reclaim('orphan objects', reclaimOrphans);
    } finally {
      _running = false;
    }
  }

  Future<int> _reclaim(String what, Future<int> Function() reclaim) async {
    try {
      final count = await reclaim();
      if (count > 0) {
        _log.info(LogEvent('reclaimed $what', {'count': count}));
      }
      return count;
    } catch (error, stackTrace) {
      _log.warning('failed to reclaim $what', error, stackTrace);
      return 0;
    }
  }

  /// Deletes digest-addressed objects older than [maxAge] that no version and
  /// no upstream archive record names, and returns how many.
  ///
  /// Every candidate is decided and deleted under the lock of its digest,
  /// which everything writing that digest holds too, and a candidate whose
  /// lock is busy waits for the next run. So nothing is deleted while a lock
  /// is live, and [maxAge] covers a holder that crashed and whose lock has
  /// expired: nothing younger than that is ever deleted.
  Future<int> reclaimOrphans(
      {DateTime? now, Duration maxAge = temporaryFileMaxAge}) async {
    final references = this.references;
    if (references == null) return 0;
    final cutoff = (now ?? DateTime.now()).subtract(maxAge);
    final referenced = await references.digests();
    var count = 0;
    for (final object in await store.listObjects()) {
      if (!object.modified.isBefore(cutoff) ||
          referenced.contains(object.digest)) {
        continue;
      }
      try {
        if (await _reclaimUnderLock(object, cutoff, references)) count++;
      } catch (error, stackTrace) {
        _log.warning(
            LogEvent('failed to reclaim an orphan object',
                {'name': object.name, 'version': object.version}),
            error,
            stackTrace);
      }
    }
    return count;
  }

  /// Deletes [object] if it still is an orphan, and returns whether it did.
  Future<bool> _reclaimUnderLock(StoredObject object, DateTime cutoff,
      ArchiveReferences references) async {
    final lock = await references.objectLocks.tryLock(object.digest);
    if (lock == null) return false;
    try {
      if (!await _isOrphan(object, cutoff, references)) return false;
      if (!await lock.confirm()) return false;
      await store.removeObject(object);
      return true;
    } finally {
      await lock.release();
    }
  }

  /// Asks again for the one object about to go, because the listing above can
  /// be out of date by now. The hash protects a file that only looks like an
  /// object, such as a legacy archive whose prerelease version is 64 hex
  /// characters long.
  Future<bool> _isOrphan(StoredObject object, DateTime cutoff,
      ArchiveReferences references) async {
    final modified = await store.objectModified(object);
    if (modified == null || !modified.isBefore(cutoff)) return false;
    if (await references.isReferenced(object.digest)) return false;
    final digest = await sha256.bind(store.readObject(object)).first;
    return digest.toString() == object.digest;
  }
}
