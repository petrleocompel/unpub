/// How long a value waits for the page that shows it.
const flashMaxAge = Duration(minutes: 5);

/// The most values waiting at once, so that sessions that never come back
/// cannot grow the map without bound.
const _maxEntries = 1000;

/// One-shot values for the next page a session sees, such as a secret that a
/// form post created and the page it redirects to shows once.
///
/// The values stay in the memory of this process, never in the database, as
/// they are secrets. Behind a load balancer the page after the redirect has
/// to reach the same instance, otherwise it says that the secret can no
/// longer be shown.
class Flash {
  final Duration maxAge;
  final DateTime Function() clock;
  final _entries = <(String, String), (Object, DateTime)>{};

  Flash({this.maxAge = flashMaxAge, this.clock = DateTime.now});

  /// Keeps [value] under [slot] for [session], replacing what was there.
  void put(String session, String slot, Object value) {
    _prune();
    if (_entries.length >= _maxEntries) _entries.remove(_entries.keys.first);
    _entries[(session, slot)] = (value, clock().add(maxAge));
  }

  /// The value under [slot] for [session], removed, or null if there is none
  /// that is younger than [maxAge] and a [T].
  T? take<T extends Object>(String session, String slot) {
    _prune();
    final value = _entries.remove((session, slot))?.$1;
    return value is T ? value : null;
  }

  void _prune() {
    final now = clock();
    _entries.removeWhere((_, entry) => !entry.$2.isAfter(now));
  }
}
