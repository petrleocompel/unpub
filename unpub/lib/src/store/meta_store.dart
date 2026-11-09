import 'package:unpub/src/models.dart';

import 'object_locks.dart';

/// The version being added is already published.
class VersionExistsException implements Exception {
  final String name;
  final String version;

  const VersionExistsException(this.name, this.version);

  @override
  String toString() => '$name@$version already exists';
}

abstract class MetaStore {
  /// The locks that publishing takes around an object and the version naming
  /// it. A store shared between instances has to override this with locks they
  /// share too.
  late final ObjectLocks objectLocks = LocalObjectLocks();

  Future<UnpubPackage?> queryPackage(String name);

  /// Adds [version] to the package [name], creating the package if needed.
  ///
  /// Throws a [VersionExistsException], changing nothing, if the package
  /// already has that version, also when another call added it just now.
  Future<void> addVersion(String name, UnpubVersion version);

  /// Replaces the stored version with the same number as [version], which is
  /// what publishing over an existing version does, if its hash is still
  /// [expectedSha256], null meaning that it has none.
  ///
  /// Returns false, changing nothing, if it no longer is, so that of two
  /// concurrent replacements only one can win.
  Future<bool> replaceVersion(String name, UnpubVersion version,
      {required String? expectedSha256});

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
