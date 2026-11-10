import 'package:unpub/src/models.dart';

import '../utils.dart';
import 'object_locks.dart';

/// How a package search is ordered.
enum PackageSort {
  /// Best match first, for a search with text, then most downloaded.
  relevance,

  /// Most downloaded first.
  downloads,

  /// Most recently published first.
  updated,

  /// By name.
  name,
}

/// The SDK a package is for. A package is a Flutter package if any of its
/// versions has a `flutter` section, an `environment.flutter` constraint or a
/// dependency on `flutter`.
enum SdkFilter { dart, flutter }

/// The last page a search reads, zero-based, and the most packages on one,
/// so that the offset of a page stays small.
const maxSearchPage = 99999;
const maxSearchSize = 1000;

/// A search of the package list.
class PackageSearch {
  /// Words that must each appear, ignoring case, in the name or a
  /// description.
  final String? text;
  final SdkFilter? sdk;
  final bool includeDiscontinued;
  final PackageSort sort;

  /// Zero-based.
  final int page;
  final int size;

  const PackageSearch({
    this.text,
    this.sdk,
    this.includeDiscontinued = false,
    this.sort = PackageSort.downloads,
    this.page = 0,
    this.size = 20,
  });

  /// How many packages a page has, [size] within 1 and [maxSearchSize].
  int get limit => size.clamp(1, maxSearchSize);

  /// How many packages come before [page], which is kept within 0 and
  /// [maxSearchPage].
  int get offset => page.clamp(0, maxSearchPage) * limit;

  /// The words of [text], lowercase, without duplicates and at most eight.
  List<String> get words => {
        for (final word in (text ?? '').toLowerCase().split(RegExp(r'\s+')))
          if (word.isNotEmpty) word,
      }.take(8).toList();

  /// Whether [package] matches the text, SDK and discontinued filters.
  bool matches(UnpubPackage package) {
    if (!includeDiscontinued && package.isDiscontinued) return false;
    if (sdk != null) {
      final flutter =
          package.versions.any((version) => isFlutterPubspec(version.pubspec));
      if (flutter != (sdk == SdkFilter.flutter)) return false;
    }
    final name = package.name.toLowerCase();
    final descriptions = [
      for (final version in package.versions)
        if (version.pubspec['description'] case final String description)
          description.toLowerCase(),
    ];
    return words.every((word) =>
        name.contains(word) ||
        descriptions.any((description) => description.contains(word)));
  }

  /// Orders [a] before [b] as [sort] asks.
  int compare(UnpubPackage a, UnpubPackage b) {
    final order = switch (sort) {
      PackageSort.relevance => _nameMatch(b).compareTo(_nameMatch(a)) != 0
          ? _nameMatch(b).compareTo(_nameMatch(a))
          : (b.download ?? 0).compareTo(a.download ?? 0),
      PackageSort.downloads => (b.download ?? 0).compareTo(a.download ?? 0),
      PackageSort.updated => b.updatedAt.compareTo(a.updatedAt),
      PackageSort.name => 0,
    };
    return order != 0 ? order : a.name.compareTo(b.name);
  }

  /// How many of the words are in the name of [package].
  int _nameMatch(UnpubPackage package) =>
      words.where((word) => package.name.contains(word)).length;
}

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

  /// The packages matching [search], and how many match in all.
  ///
  /// This implementation filters every package in memory, which suits a
  /// small store. [MongoStore] runs the search in the database.
  Future<UnpubQueryResult> searchPackages(PackageSearch search) async {
    final all = await queryPackages(size: 1 << 20, page: 0, sort: 'name');
    final matching = all.packages.where(search.matches).toList()
      ..sort(search.compare);
    return UnpubQueryResult(matching.length,
        matching.skip(search.offset).take(search.limit).toList());
  }

  /// Which of [names] are packages in this store.
  Future<Set<String>> existingPackageNames(Iterable<String> names) async => {
        for (final name in names)
          if (await queryPackage(name) != null) name,
      };

  /// Throws if the store cannot currently serve requests.
  Future<void> checkHealth() async {}
}
