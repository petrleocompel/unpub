import 'dart:async';
import 'dart:io';

int _temporaryFiles = 0;

final _digestPattern = RegExp(r'^[0-9a-f]{64}$');

abstract class PackageStore {
  bool supportsDownloadUrl = false;

  FutureOr<String> downloadUrl(String name, String version) {
    throw 'downloadUri not implemented';
  }

  Stream<List<int>> download(String name, String version) {
    throw 'download not implemented';
  }

  Future<void> upload(String name, String version, List<int> content);

  /// Whether the archive of [name] [version] is stored.
  ///
  /// Stores that cannot tell cheaply may keep this default, and then fail when
  /// the archive is requested.
  Future<bool> exists(String name, String version) async => true;

  /// A new file to write an upstream archive to while it is fetched, in a
  /// place where [commitUpstream] can take it from.
  Future<File> upstreamTemporaryFile(String name, String version) async =>
      File('${Directory.systemTemp.path}/'
          'unpub-upstream-$pid-${_temporaryFiles++}-'
          '${DateTime.now().microsecondsSinceEpoch}.tmp');

  /// Keeps [temporary], an upstream archive of [size] bytes whose SHA-256 is
  /// [digest], apart from locally published ones, and returns whether it was
  /// kept.
  ///
  /// The object is named by [digest] and never changes: committing bytes that
  /// are already kept leaves them as they are. Which object is current is only
  /// ever said by the record in the upstream cache.
  ///
  /// A store that keeps this default caches nothing, so the proxy goes to the
  /// upstream on every download.
  Future<bool> commitUpstream(String name, String version, String digest,
          File temporary, int size) async =>
      false;

  /// Whether the upstream archive with this [digest] is kept.
  Future<bool> upstreamCached(
          String name, String version, String digest) async =>
      false;

  /// The upstream archive with this [digest]. Only valid if [upstreamCached].
  Stream<List<int>> downloadUpstream(
      String name, String version, String digest) {
    throw 'downloadUpstream not implemented';
  }

  /// Forgets the upstream archive with this [digest], if it is kept.
  Future<void> deleteUpstream(
      String name, String version, String digest) async {}

  /// Throws an [ArgumentError] unless [digest] is a lowercase hex SHA-256, for
  /// stores that build a path or key from one.
  static void checkDigest(String digest) {
    if (!_digestPattern.hasMatch(digest)) {
      throw ArgumentError('not a SHA-256 digest');
    }
  }

  /// Throws if the store cannot currently serve requests.
  Future<void> checkHealth() async {}
}
