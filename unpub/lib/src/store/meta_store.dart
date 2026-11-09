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

  Future<void> addUploader(String name, String email);

  Future<void> removeUploader(String name, String email);

  void increaseDownloads(String name, String version);

  /// How many downloads of [version] of [name] have been counted.
  Future<int> versionDownloads(String name, String version);

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
