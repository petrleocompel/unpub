import 'dart:io';

import 'package:path/path.dart' as path;

import 'package_store.dart';

class FileStore extends PackageStore {
  String baseDir;

  /// Where the archive of a version lives in the mutable layout from before
  /// archives were named by their digest, relative to [baseDir]. Archives
  /// already there keep being served from it, and nothing new is written.
  String Function(String name, String version)? getFilePath;

  /// Where the immutable object with a digest lives, relative to [baseDir],
  /// instead of `<name>/<name>-<version>-<sha256>.tar.gz`.
  String Function(String name, String version, String sha256)? getObjectPath;

  /// Throws an [ArgumentError] if [getFilePath] or [getObjectPath] answers a
  /// path inside [temporaryNamespace].
  FileStore(this.baseDir, {this.getFilePath, this.getObjectPath}) {
    final file = getFilePath;
    if (file != null) {
      PackageStore.checkLayout(() => file('a_package', '1.0.0'));
    }
    final object = getObjectPath;
    if (object != null) {
      PackageStore.checkLayout(() => object('a_package', '1.0.0', '0' * 64));
    }
  }

  /// The archive of [name] [version], which is always inside [baseDir].
  ///
  /// Throws an [ArgumentError] for a path that would leave [baseDir].
  File _getTarballFile(String name, String version) =>
      _inBaseDir(getFilePath?.call(name, version) ?? '$name-$version.tar.gz');

  /// The immutable object of a published archive.
  File _getObjectFile(String name, String version, String digest) {
    PackageStore.checkDigest(digest);
    return _inBaseDir(getObjectPath?.call(name, version, digest) ??
        path.join(name, '$name-$version-$digest.tar.gz'));
  }

  /// A proxied archive, under `upstream/`, named by the digest of its bytes.
  /// A locally published archive never lands there, whatever the name, because
  /// its object has one directory fewer.
  File _getUpstreamFile(String name, String version, String digest) {
    PackageStore.checkDigest(digest);
    return _inBaseDir(
        path.join('upstream', name, '$name-$version-$digest.tar.gz'));
  }

  File _inBaseDir(String relative) {
    final base = path.normalize(path.absolute(baseDir));
    final filePath = path.normalize(path.join(base, relative));
    if (!path.isWithin(base, filePath)) {
      throw ArgumentError('archive path escapes the storage directory');
    }
    PackageStore.checkNotReserved(path.relative(filePath, from: base));
    return File(filePath);
  }

  Directory get _temporaryDirectory =>
      Directory(path.join(baseDir, temporaryNamespace));

  /// A new temporary file. It is on the same disk as every object, so that
  /// moving it there is atomic and a partial file is never served.
  Future<File> _newTemporaryFile() async {
    final directory = await _temporaryDirectory.create(recursive: true);
    return File(path.join(directory.path, PackageStore.newTemporaryName()));
  }

  @override
  Future<void> upload(String name, String version, List<int> content) async {
    var file = _getTarballFile(name, version);
    await file.create(recursive: true);
    await file.writeAsBytes(content);
  }

  @override
  Future<bool> exists(String name, String version) =>
      _getTarballFile(name, version).exists();

  @override
  Stream<List<int>> download(String name, String version) {
    return _getTarballFile(name, version).openRead();
  }

  /// Identical digests mean identical bytes, so an object that is already there
  /// stays, with a new modification time that keeps reclamation away from it
  /// until the metadata has been written.
  @override
  Future<void> storeObject(
      String name, String version, String digest, List<int> content) async {
    final target = _getObjectFile(name, version, digest);
    try {
      await target.setLastModified(DateTime.now());
      return;
    } on FileSystemException {
      // Not stored yet.
    }
    final temporary = await _newTemporaryFile();
    try {
      final output = await temporary.open(mode: FileMode.writeOnly);
      try {
        await output.writeFrom(content);
        await output.flush();
      } finally {
        await output.close();
      }
      await target.parent.create(recursive: true);
      await temporary.rename(target.path);
    } catch (_) {
      await _deleteIfPresent(temporary);
      rethrow;
    }
  }

  @override
  Future<bool> objectExists(String name, String version, String digest) =>
      _getObjectFile(name, version, digest).exists();

  @override
  Stream<List<int>> downloadObject(
          String name, String version, String digest) =>
      _getObjectFile(name, version, digest).openRead();

  @override
  Future<void> deleteObject(String name, String version, String digest) =>
      _deleteIfPresent(_getObjectFile(name, version, digest));

  static Future<void> _deleteIfPresent(File file) async {
    try {
      await file.delete();
    } on PathNotFoundException {
      // Never written, or another instance got there first.
    }
  }

  @override
  Future<File> upstreamTemporaryFile(String name, String version) =>
      _newTemporaryFile();

  /// Identical digests mean identical bytes, so an archive that is already
  /// there stays and [temporary] is dropped.
  @override
  Future<bool> commitUpstream(String name, String version, String digest,
      File temporary, int size) async {
    final target = _getUpstreamFile(name, version, digest);
    if (await target.exists()) {
      // Make it young again: reclamation leaves alone what changed within the
      // hour, so the object outlives a lease lost right after this.
      await target.setLastModified(DateTime.now());
      await temporary.delete();
      return true;
    }
    await _flushToDisk(temporary);
    await target.parent.create(recursive: true);
    await temporary.rename(target.path);
    return true;
  }

  static Future<void> _flushToDisk(File file) async {
    final handle = await file.open(mode: FileMode.append);
    try {
      await handle.flush();
    } finally {
      await handle.close();
    }
  }

  @override
  Future<bool> upstreamCached(String name, String version, String digest) =>
      _getUpstreamFile(name, version, digest).exists();

  @override
  Stream<List<int>> downloadUpstream(
          String name, String version, String digest) =>
      _getUpstreamFile(name, version, digest).openRead();

  @override
  Future<void> deleteUpstream(String name, String version, String digest) =>
      _deleteIfPresent(_getUpstreamFile(name, version, digest));

  @override
  Future<int> reclaimTemporary(
          {DateTime? now, Duration maxAge = temporaryFileMaxAge}) =>
      PackageStore.reclaimDirectory(
          _temporaryDirectory, (now ?? DateTime.now()).subtract(maxAge));

  /// A custom [getObjectPath] cannot be listed, so its objects are left alone
  /// and only `upstream/` is looked at.
  @override
  Future<List<StoredObject>> listObjects() async {
    final base = path.normalize(path.absolute(baseDir));
    final directory = Directory(base);
    if (!await directory.exists()) return const [];
    final objects = <StoredObject>[];
    await for (final entity
        in directory.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final location = path.split(path.relative(entity.path, from: base));
      if (location.first == temporaryNamespace) continue;
      final FileStat stat;
      try {
        stat = await entity.stat();
      } on FileSystemException {
        continue;
      }
      final object =
          PackageStore.parseObject(location.join('/'), stat.modified);
      if (object != null && (object.upstream || getObjectPath == null)) {
        objects.add(object);
      }
    }
    return objects;
  }

  @override
  Future<DateTime?> objectModified(StoredObject object) async {
    final file = object.upstream
        ? _getUpstreamFile(object.name, object.version, object.digest)
        : _getObjectFile(object.name, object.version, object.digest);
    final stat = await file.stat();
    return stat.type == FileSystemEntityType.notFound ? null : stat.modified;
  }

  /// Creates [baseDir] if it is missing, and returns whether it did.
  ///
  /// Call this once at startup, so that [checkHealth] can report a directory
  /// that has gone missing instead of quietly recreating it.
  Future<bool> createBaseDir() async {
    final directory = Directory(baseDir);
    if (await directory.exists()) return false;
    await directory.create(recursive: true);
    return true;
  }

  /// Verifies [baseDir] exists and is writable by writing a probe file.
  @override
  Future<void> checkHealth() async {
    if (!await Directory(baseDir).exists()) {
      throw FileSystemException('storage directory does not exist', baseDir);
    }
    final stamp = '$pid-${DateTime.now().microsecondsSinceEpoch}';
    final probe = File(path.join(baseDir, '.unpub-health-$stamp'));
    await probe.writeAsString('ok');
    await probe.delete();
  }
}
