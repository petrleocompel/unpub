import 'dart:async';

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

  /// Keeps a copy of an upstream archive, apart from locally published ones.
  ///
  /// A store that keeps this default caches nothing, so the proxy goes to the
  /// upstream on every download.
  Future<void> cacheUpstream(
      String name, String version, List<int> content) async {}

  /// Whether a copy of this upstream archive is kept.
  Future<bool> upstreamCached(String name, String version) async => false;

  /// The copy of this upstream archive. Only valid if [upstreamCached].
  Stream<List<int>> downloadUpstream(String name, String version) {
    throw 'downloadUpstream not implemented';
  }

  /// Throws if the store cannot currently serve requests.
  Future<void> checkHealth() async {}
}
