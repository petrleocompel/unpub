import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;

int _temporaryFiles = 0;

/// How old a temporary file has to be before it counts as left behind. Long
/// enough that a fetch or publish that is still running has touched it since.
const temporaryFileMaxAge = Duration(hours: 1);

final _spoolFilePattern = RegExp(r'^unpub-upstream-\d+-\d+-\d+\.tmp$');
final _digestPattern = RegExp(r'^[0-9a-f]{64}$');
final _stagingIdPattern = RegExp(r'^[0-9A-Za-z]+$');

/// Storage holds an archive for a version no published version accounts for,
/// so publishing it would overwrite bytes that nobody can vouch for.
class ArchiveExistsException implements Exception {
  final String name;
  final String version;

  const ArchiveExistsException(this.name, this.version);

  @override
  String toString() => 'storage is corrupt: an archive of $name@$version is '
      'already stored and no published version accounts for it, so it was not '
      'overwritten. An administrator has to check it and remove it first.';
}

abstract class PackageStore {
  final _staged = <String, List<int>>{};

  bool supportsDownloadUrl = false;

  FutureOr<String> downloadUrl(String name, String version) {
    throw 'downloadUri not implemented';
  }

  Stream<List<int>> download(String name, String version) {
    throw 'download not implemented';
  }

  Future<void> upload(String name, String version, List<int> content);

  /// Puts [content] where no download can reach it, for [commitStaged] or
  /// [discardStaged]. [id] tells apart attempts at publishing one version.
  ///
  /// A store that keeps these defaults holds the archive in memory and only
  /// gets to see it in [upload], at commit.
  Future<void> stageArchive(
      String name, String version, String id, List<int> content) async {
    _staged['$name@$version#$id'] = content;
  }

  /// Makes a staged archive the published one. Unless [replace] is set, throws
  /// an [ArchiveExistsException] rather than overwrite an archive.
  Future<void> commitStaged(String name, String version, String id,
      {bool replace = false}) async {
    final content = _staged.remove('$name@$version#$id');
    if (content == null) throw StateError('nothing staged for $name@$version');
    await upload(name, version, content);
  }

  /// Forgets a staged archive, if there is one.
  Future<void> discardStaged(String name, String version, String id) async {
    _staged.remove('$name@$version#$id');
  }

  /// Whether [commitStaged] would find the archive of [name] [version] there
  /// already. Unlike [exists], a store that cannot tell answers false.
  Future<bool> hasCommittedArchive(String name, String version) async => false;

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

  /// Throws an [ArgumentError] for an id that could change a path or key.
  static void checkStagingId(String id) {
    if (!_stagingIdPattern.hasMatch(id)) {
      throw ArgumentError('unsafe staging id');
    }
  }

  /// Deletes temporary files older than [maxAge] that a crash left behind, and
  /// returns how many. Nothing that does not carry the temporary naming of
  /// this store is touched.
  Future<int> reclaimTemporary(
      {DateTime? now, Duration maxAge = temporaryFileMaxAge}) async {
    final cutoff = (now ?? DateTime.now()).subtract(maxAge);
    var count = 0;
    await for (final entity in Directory.systemTemp.list(followLinks: false)) {
      if (entity is! File ||
          !_spoolFilePattern.hasMatch(path.basename(entity.path))) {
        continue;
      }
      try {
        if ((await entity.stat()).modified.isBefore(cutoff)) {
          await entity.delete();
          count++;
        }
      } on FileSystemException {
        // Finished, or another instance got there first.
      }
    }
    return count;
  }

  /// Throws if the store cannot currently serve requests.
  Future<void> checkHealth() async {}
}
