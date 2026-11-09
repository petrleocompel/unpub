import 'dart:async';

import 'package:logging/logging.dart';

import '../logging.dart';
import 'package_store.dart';

final _log = Logger('unpub.reclaim');

/// Deletes the temporary files a crash left in a store, at startup and then
/// periodically.
class TemporaryReclaimer {
  final PackageStore store;
  final Duration interval;
  Timer? _timer;
  bool _running = false;

  TemporaryReclaimer(this.store, {this.interval = const Duration(hours: 1)});

  void start() {
    unawaited(run());
    _timer = Timer.periodic(interval, (_) => unawaited(run()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Returns how many files were deleted. A failure is only logged, because
  /// the next run tries again.
  Future<int> run() async {
    if (_running) return 0;
    _running = true;
    try {
      final count = await store.reclaimTemporary();
      if (count > 0) {
        _log.info(LogEvent('reclaimed temporary files', {'count': count}));
      }
      return count;
    } catch (error, stackTrace) {
      _log.warning('failed to reclaim temporary files', error, stackTrace);
      return 0;
    } finally {
      _running = false;
    }
  }
}
