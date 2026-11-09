import 'package:unpub/src/models.dart';

abstract class MetaStore {
  Future<UnpubPackage?> queryPackage(String name);

  /// Adds [version] to the package [name], creating the package if needed.
  ///
  /// Returns false, changing nothing, if the package already has that version.
  Future<bool> addVersion(String name, UnpubVersion version);

  /// Replaces the stored version with the same number as [version], which is
  /// what publishing over an existing version does.
  Future<void> replaceVersion(String name, UnpubVersion version);

  /// Claims the right to store the archive of [name] [version], so that a
  /// concurrent publish, also from another server, cannot overwrite it.
  ///
  /// Returns what to pass to [releaseUpload], or null if another request holds
  /// the claim. A store shared by one process can keep this default, because
  /// [App] already serializes publishes within a process.
  Future<String?> reserveUpload(String name, String version) async =>
      DateTime.now().microsecondsSinceEpoch.toString();

  /// Extends a claim made by [reserveUpload], and returns whether it was still
  /// held.
  Future<bool> renewUpload(
          String name, String version, String reservation) async =>
      true;

  /// Gives up a claim made by [reserveUpload].
  Future<void> releaseUpload(
      String name, String version, String reservation) async {}

  Future<void> addUploader(String name, String email);

  Future<void> removeUploader(String name, String email);

  void increaseDownloads(String name, String version);

  /// How many downloads of [version] of [name] have been counted.
  Future<int> versionDownloads(String name, String version);

  /// How many downloads of each of [versions] of [name] have been counted.
  Future<Map<String, int>> versionDownloadCounts(
          String name, Iterable<String> versions) async =>
      {for (final v in versions) v: await versionDownloads(name, v)};

  /// Marks a version as retracted, or restores it when [retracted] is false.
  ///
  /// Returns false if the version was already in that state.
  Future<bool> setVersionRetracted(
    String name,
    String version, {
    required bool retracted,
    DateTime? retractedAt,
    String? retractedBy,
  });

  /// Stores whether a package is discontinued and what replaces it.
  Future<void> setDiscontinued(
    String name, {
    required bool discontinued,
    String? replacedBy,
    DateTime? discontinuedAt,
  });

  Future<UnpubQueryResult> queryPackages({
    required int size,
    required int page,
    required String sort,
    String? keyword,
    String? uploader,
    String? dependency,
    bool includeDiscontinued = true,
  });

  /// Throws if the store cannot currently serve requests.
  Future<void> checkHealth() async {}
}
