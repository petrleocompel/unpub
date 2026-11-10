import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;

int _temporaryFiles = 0;

/// How old a temporary file has to be before it counts as left behind. Long
/// enough that a fetch or publish that is still running has touched it since.
const temporaryFileMaxAge = Duration(hours: 1);

/// The directory, or S3 key prefix, that holds every temporary file a store
/// writes. Nothing else may be stored there, and reclamation never deletes
/// anything outside it.
const temporaryNamespace = '.unpub-tmp';

final _digestPattern = RegExp(r'^[0-9a-f]{64}$');

/// The default layout of an object, published or under `upstream/`.
final _objectPattern = RegExp(
    r'^(upstream/)?([a-z_][a-z0-9_]*)/\2-([^/]+)-([0-9a-f]{64})\.tar\.gz$');

/// An immutable object found in a store, named by the digest of its bytes.
class StoredObject {
  final String name;
  final String version;
  final String digest;

  /// Whether this is a proxied archive rather than a published one.
  final bool upstream;
  final DateTime modified;

  const StoredObject(
      this.name, this.version, this.digest, this.upstream, this.modified);
}

abstract class PackageStore {
  bool supportsDownloadUrl = false;

  FutureOr<String> downloadUrl(String name, String version) {
    throw 'downloadUri not implemented';
  }

  Stream<List<int>> download(String name, String version) {
    throw 'download not implemented';
  }

  /// Stores [content] at the mutable path of [name] [version], the layout
  /// archives had before they were named by their digest.
  Future<void> upload(String name, String version, List<int> content);

  /// Stores [content], whose SHA-256 is [digest], as an immutable object.
  ///
  /// Nothing refers to the object until a version names its digest, so this
  /// cannot change what is being downloaded. Storing a digest that is already
  /// there leaves the same bytes, and must make the object count as new again
  /// so that reclamation leaves it alone until the metadata has been written.
  ///
  /// A store that keeps this default has no immutable objects: it writes to
  /// the mutable path through [upload], so a publish that loses the metadata
  /// write can overwrite the bytes of the one that won.
  Future<void> storeObject(
          String name, String version, String digest, List<int> content) =>
      upload(name, version, content);

  /// Whether the object with this [digest] is stored.
  Future<bool> objectExists(String name, String version, String digest) =>
      exists(name, version);

  /// The object with this [digest]. Only valid if [objectExists].
  Stream<List<int>> downloadObject(
          String name, String version, String digest) =>
      download(name, version);

  /// Where the object with this [digest] can be fetched from, for a store with
  /// [supportsDownloadUrl].
  FutureOr<String> objectDownloadUrl(
          String name, String version, String digest) =>
      downloadUrl(name, version);

  /// Deletes the object with this [digest], if it is stored.
  Future<void> deleteObject(String name, String version, String digest) async {}

  /// Deletes the archive at the mutable path of [name] [version], if it is
  /// stored there.
  Future<void> deleteLegacy(String name, String version) async {}

  /// Whether the archive of [name] [version] is stored.
  ///
  /// Stores that cannot tell cheaply may keep this default, and then fail when
  /// the archive is requested.
  Future<bool> exists(String name, String version) async => true;

  /// A new file to write an upstream archive to while it is fetched, in a
  /// place where [commitUpstream] can take it from.
  Future<File> upstreamTemporaryFile(String name, String version) async {
    final directory = await Directory(
            path.join(Directory.systemTemp.path, temporaryNamespace))
        .create(recursive: true);
    return File(path.join(directory.path, newTemporaryName()));
  }

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

  /// The objects in this store that have the default layout, for reclamation.
  /// A store that keeps this default reports none and is left alone.
  Future<List<StoredObject>> listObjects() async => const [];

  /// When [object] was last written, or null if it is gone.
  Future<DateTime?> objectModified(StoredObject object) async => null;

  Stream<List<int>> readObject(StoredObject object) => object.upstream
      ? downloadUpstream(object.name, object.version, object.digest)
      : downloadObject(object.name, object.version, object.digest);

  Future<void> removeObject(StoredObject object) => object.upstream
      ? deleteUpstream(object.name, object.version, object.digest)
      : deleteObject(object.name, object.version, object.digest);

  /// The object stored under [location], a `/` separated path or key in the
  /// default layout, or null for anything else.
  static StoredObject? parseObject(String location, DateTime modified) {
    final match = _objectPattern.firstMatch(location);
    if (match == null) return null;
    return StoredObject(
        match[2]!, match[3]!, match[4]!, match[1] != null, modified);
  }

  /// Whether [digest] is a lowercase hex SHA-256, and so can name an object.
  static bool isDigest(String digest) => _digestPattern.hasMatch(digest);

  /// Throws an [ArgumentError] if the relative path or key [location] is in
  /// [temporaryNamespace].
  static void checkNotReserved(String location) {
    final first = path.split(path.normalize(location)).first;
    if (first.toLowerCase() == temporaryNamespace) {
      throw ArgumentError(
          'an archive path must not be inside $temporaryNamespace/');
    }
  }

  /// Throws an [ArgumentError] if [layout], a custom path function called with
  /// sample values, answers a path in [temporaryNamespace], so that such a
  /// configuration fails at startup rather than at the first publish.
  ///
  /// A function that cannot handle the sample is still checked on every call.
  static void checkLayout(String Function() layout) {
    final String location;
    try {
      location = layout();
    } catch (_) {
      return;
    }
    checkNotReserved(location);
  }

  /// A file name for a new temporary file. It says nothing about the archive,
  /// so reclamation does not depend on the layout of the final path.
  static String newTemporaryName() => '$pid-${_temporaryFiles++}-'
      '${DateTime.now().microsecondsSinceEpoch}.tmp';

  /// Deletes the files in [directory] last modified before [cutoff], and
  /// returns how many.
  static Future<int> reclaimDirectory(
      Directory directory, DateTime cutoff) async {
    if (!await directory.exists()) return 0;
    var count = 0;
    await for (final entity
        in directory.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
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

  /// Deletes temporary files older than [maxAge] that a crash left behind, and
  /// returns how many. Only [temporaryNamespace] is ever touched.
  Future<int> reclaimTemporary(
          {DateTime? now, Duration maxAge = temporaryFileMaxAge}) =>
      reclaimDirectory(
          Directory(path.join(Directory.systemTemp.path, temporaryNamespace)),
          (now ?? DateTime.now()).subtract(maxAge));

  /// Throws if the store cannot currently serve requests.
  Future<void> checkHealth() async {}
}
