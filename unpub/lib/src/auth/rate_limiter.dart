import 'dart:collection' show Queue;
import 'dart:math';

import 'package:logging/logging.dart';

final _log = Logger('unpub.login_limit');

/// Limits failed logins per client address and per email, within one process.
///
/// Memory is bounded by [maxKeys]. A flood of new keys must not be able to
/// erase the counters it wants gone, so only expired counters and those far
/// from the limit are ever forgotten. When there are no such counters, new
/// keys are refused rather than tracked or let through.
class LoginRateLimiter {
  final int maxFailures;
  final Duration window;
  final DateTime Function() clock;

  /// The most addresses and emails tracked at once.
  final int maxKeys;

  /// Attempts by key, oldest key first. Bounded by [maxKeys].
  final _attempts = <String, Queue<DateTime>>{};

  /// How long to wait, as reported to a key refused for lack of room.
  static const _refusedWait = Duration(minutes: 1);

  /// How often a limiter that found nothing to forget looks again. Scanning
  /// every key on each request would give a flood cheap work to cause.
  static const _evictionPause = Duration(seconds: 1);
  static const _warningInterval = Duration(minutes: 1);

  DateTime? _nextEviction;
  DateTime? _nextWarning;

  LoginRateLimiter({
    this.maxFailures = 10,
    this.window = const Duration(minutes: 15),
    this.clock = DateTime.now,
    this.maxKeys = 50000,
  });

  /// From this many attempts a key is never forgotten before it expires.
  int get _protectedFrom => (maxFailures / 2).ceil();

  static String _addressKey(String? address) => 'ip:${address ?? 'unknown'}';
  static String _emailKey(String email) => 'email:$email';

  /// Counts an attempt, or returns how long to wait if the limit is reached.
  ///
  /// The attempt is counted before the password is checked, so that parallel
  /// requests cannot all slip in while hashing is in progress. A successful
  /// login takes it back with [succeeded].
  Duration? acquire(String? address, String email) {
    final now = clock();
    final keys = [_addressKey(address), _emailKey(email)];
    Duration? wait;
    for (final key in keys) {
      final attempts = _pruned(key, now);
      if (attempts != null && attempts.length >= maxFailures) {
        final free = attempts.first.add(window).difference(now);
        wait = wait == null
            ? free
            : Duration(
                microseconds: max(wait.inMicroseconds, free.inMicroseconds));
      }
    }
    if (wait != null) return wait;
    if (!_hasRoomFor(keys, now)) return _refused(now);
    for (final key in keys) {
      (_attempts[key] ??= Queue()).addLast(now);
    }
    return null;
  }

  /// Forgets the failures of [email], and the current attempt of [address].
  ///
  /// The failures of the address stay, or one valid account would let its
  /// owner keep guessing the passwords of others.
  void succeeded(String? address, String email) {
    _attempts.remove(_emailKey(email));
    final key = _addressKey(address);
    final attempts = _attempts[key];
    if (attempts == null || attempts.isEmpty) return;
    attempts.removeLast();
    if (attempts.isEmpty) _attempts.remove(key);
  }

  Queue<DateTime>? _pruned(String key, DateTime now) {
    final attempts = _attempts[key];
    if (attempts == null) return null;
    final oldest = now.subtract(window);
    while (attempts.isNotEmpty && !attempts.first.isAfter(oldest)) {
      attempts.removeFirst();
    }
    if (attempts.isEmpty) {
      _attempts.remove(key);
      return null;
    }
    return attempts;
  }

  bool _hasRoomFor(List<String> keys, DateTime now) {
    final missing = keys.where((key) => !_attempts.containsKey(key)).length;
    if (_attempts.length + missing <= maxKeys) return true;

    final next = _nextEviction;
    if (next != null && now.isBefore(next)) return false;
    _evict(now);
    if (_attempts.length + missing <= maxKeys) {
      _nextEviction = null;
      return true;
    }
    _nextEviction = now.add(_evictionPause);
    return false;
  }

  Duration _refused(DateTime now) {
    final next = _nextWarning;
    if (next == null || !now.isBefore(next)) {
      _log.warning('too many login attempts are being tracked, refusing '
          'attempts from new addresses and for new emails');
      _nextWarning = now.add(_warningInterval);
    }
    return _refusedWait;
  }

  /// Forgets expired keys, then the keys with the fewest attempts, to leave
  /// room for many new keys before this has to run again.
  void _evict(DateTime now) {
    for (final key in _attempts.keys.toList()) {
      _pruned(key, now);
    }
    final target = maxKeys - max(2, maxKeys ~/ 10);
    for (var count = 1; count < _protectedFrom; count++) {
      for (final key in _attempts.keys.toList()) {
        if (_attempts.length <= target) return;
        if (_attempts[key]!.length == count) _attempts.remove(key);
      }
    }
  }
}
