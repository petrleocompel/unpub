import 'dart:async';
import 'dart:io';

int _temporaryFiles = 0;

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

  /// Keeps [temporary], a verified upstream archive of [size] bytes, apart
  /// from locally published ones, and returns whether it was kept.
  ///
  /// A store that keeps this default caches nothing, so the proxy goes to the
  /// upstream on every download.
  Future<bool> commitUpstream(
          String name, String version, File temporary, int size) async =>
      false;

  /// Whether a copy of this upstream archive is kept.
  Future<bool> upstreamCached(String name, String version) async => false;

  /// The copy of this upstream archive. Only valid if [upstreamCached].
  Stream<List<int>> downloadUpstream(String name, String version) {
    throw 'downloadUpstream not implemented';
  }

  /// Forgets the copy of this upstream archive, if there is one.
  Future<void> deleteUpstream(String name, String version) async {}

  /// Throws if the store cannot currently serve requests.
  Future<void> checkHealth() async {}
}
