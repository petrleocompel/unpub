import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/key_derivators/api.dart';
import 'package:pointycastle/key_derivators/argon2.dart';

const _version = Argon2Parameters.ARGON2_VERSION_13;
const _saltLength = 16;
const _outputLength = 32;

/// Hashes wider than this are refused, so a corrupt record cannot exhaust
/// memory.
const _maxMemoryKiB = 1 << 20;
const _maxIterations = 64;
const _maxLanes = 16;

final _random = Random.secure();

final _encodedPattern = RegExp(
    r'^\$argon2id\$v=19\$m=(\d+),t=(\d+),p=(\d+)\$([A-Za-z0-9+/]+)\$([A-Za-z0-9+/]+)$');

/// Argon2id password hashing, implemented in pure Dart.
///
/// Hashes use the PHC string format, such as
/// `$argon2id$v=19$m=19456,t=2,p=1$<salt>$<hash>`, which names the algorithm
/// and its cost, so both can change without invalidating stored hashes.
///
/// Derivation runs in a separate isolate so that it does not stall requests,
/// and at most [_maxConcurrent] run at once to bound memory use.
class PasswordHasher {
  static const _maxConcurrent = 4;
  static final _pool = _Pool(_maxConcurrent);

  /// The memory cost in KiB. The default and [iterations] follow the OWASP
  /// recommendation for Argon2id.
  final int memoryKiB;
  final int iterations;
  final int parallelism;

  const PasswordHasher({
    this.memoryKiB = 19456,
    this.iterations = 2,
    this.parallelism = 1,
  });

  /// Returns the encoded hash of [password] with a fresh salt.
  Future<String> hash(String password) async {
    final salt = Uint8List.fromList(
        List<int>.generate(_saltLength, (_) => _random.nextInt(256)));
    final derived = await _derive(
        password, salt, memoryKiB, iterations, parallelism, _outputLength);
    return '\$argon2id\$v=19\$m=$memoryKiB,t=$iterations,p=$parallelism'
        '\$${_encode(salt)}\$${_encode(derived)}';
  }

  /// Whether [password] matches [encoded]. An unreadable hash never matches.
  Future<bool> verify(String password, String encoded) async {
    final match = _encodedPattern.firstMatch(encoded);
    if (match == null) return false;
    final memory = int.tryParse(match.group(1)!);
    final time = int.tryParse(match.group(2)!);
    final lanes = int.tryParse(match.group(3)!);
    final salt = _decode(match.group(4)!);
    final expected = _decode(match.group(5)!);
    if (memory == null ||
        time == null ||
        lanes == null ||
        salt == null ||
        expected == null ||
        memory < 8 * max(lanes, 1) ||
        memory > _maxMemoryKiB ||
        time < 1 ||
        time > _maxIterations ||
        lanes < 1 ||
        lanes > _maxLanes ||
        expected.isEmpty) {
      return false;
    }
    final actual =
        await _derive(password, salt, memory, time, lanes, expected.length);
    var difference = 0;
    for (var i = 0; i < expected.length; i++) {
      difference |= actual[i] ^ expected[i];
    }
    return difference == 0;
  }

  static Future<Uint8List> _derive(String password, Uint8List salt, int memory,
      int time, int lanes, int length) {
    return _pool.run(() => Isolate.run(
        () => _argon2id(password, salt, memory, time, lanes, length)));
  }

  static String _encode(List<int> bytes) =>
      base64.encode(bytes).replaceAll('=', '');

  static Uint8List? _decode(String text) {
    try {
      return base64.decode(base64.normalize(text));
    } on FormatException {
      return null;
    }
  }
}

Uint8List _argon2id(String password, Uint8List salt, int memoryKiB,
    int iterations, int lanes, int length) {
  final generator = Argon2BytesGenerator()
    ..init(Argon2Parameters(
      Argon2Parameters.ARGON2_id,
      salt,
      desiredKeyLength: length,
      iterations: iterations,
      memory: memoryKiB,
      lanes: lanes,
      version: _version,
    ));
  return generator.process(Uint8List.fromList(utf8.encode(password)));
}

/// Runs at most a fixed number of tasks at once, in order of arrival.
class _Pool {
  final int _size;
  final _waiting = Queue<Completer<void>>();
  var _running = 0;

  _Pool(this._size);

  Future<T> run<T>(Future<T> Function() task) async {
    if (_running >= _size) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    } else {
      _running++;
    }
    try {
      return await task();
    } finally {
      if (_waiting.isEmpty) {
        _running--;
      } else {
        _waiting.removeFirst().complete();
      }
    }
  }
}
