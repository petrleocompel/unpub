import 'dart:collection' show Queue;
import 'dart:math';

/// Limits failed logins per client address and per email, within one process.
class LoginRateLimiter {
  final int maxFailures;
  final Duration window;
  final DateTime Function() clock;

  /// Attempts by key, oldest key first. Bounded by [_maxKeys].
  final _attempts = <String, Queue<DateTime>>{};

  static const _maxKeys = 50000;

  LoginRateLimiter({
    this.maxFailures = 10,
    this.window = const Duration(minutes: 15),
    this.clock = DateTime.now,
  });

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
    for (final key in keys) {
      (_attempts[key] ??= Queue()).addLast(now);
    }
    _evict(now);
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

  void _evict(DateTime now) {
    if (_attempts.length <= _maxKeys) return;
    for (final key in _attempts.keys.toList()) {
      _pruned(key, now);
    }
    while (_attempts.length > _maxKeys) {
      _attempts.remove(_attempts.keys.first);
    }
  }
}
