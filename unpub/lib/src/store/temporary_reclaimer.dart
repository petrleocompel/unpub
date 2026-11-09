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
  /// [maxAge] keeps this away from a publish or fetch still in progress, which
  /// writes its object before the metadata that names it. Storing a digest
  /// again makes its object new, so an identical publish is safe too.
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
        if (!await _isOrphan(object, cutoff, references)) continue;
        await store.removeObject(object);
        count++;
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
