import 'dart:io';

import 'package:path/path.dart' as path;

import 'package_store.dart';

class FileStore extends PackageStore {
  String baseDir;
  String Function(String name, String version)? getFilePath;

  FileStore(this.baseDir, {this.getFilePath});

  /// The archive of [name] [version], which is always inside [baseDir].
  ///
  /// Throws an [ArgumentError] for a path that would leave [baseDir].
  File _getTarballFile(String name, String version) =>
      _inBaseDir(getFilePath?.call(name, version) ?? '$name-$version.tar.gz');

  /// A proxied archive, under `upstream/`, named by the digest of its bytes.
  /// A locally published archive never lands there, whatever the name, because
  /// it has no directory of its own.
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
    return File(filePath);
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

  File _getStagedFile(String name, String version, String id) {
    PackageStore.checkStagingId(id);
    return File('${_getTarballFile(name, version).path}.$id.staging');
  }

  @override
  Future<void> stageArchive(
      String name, String version, String id, List<int> content) async {
    final file = _getStagedFile(name, version, id);
    await file.parent.create(recursive: true);
    final output = await file.open(mode: FileMode.writeOnly);
    try {
      await output.writeFrom(content);
      await output.flush();
    } finally {
      await output.close();
    }
  }

  @override
  Future<void> commitStaged(String name, String version, String id,
      {bool replace = false}) async {
    final target = _getTarballFile(name, version);
    if (!replace && await target.exists()) {
      throw ArchiveExistsException(name, version);
    }
    await _getStagedFile(name, version, id).rename(target.path);
  }

  @override
  Future<void> discardStaged(String name, String version, String id) async {
    try {
      await _getStagedFile(name, version, id).delete();
    } on PathNotFoundException {
      // Never written, or already committed.
    }
  }

  @override
  Future<bool> hasCommittedArchive(String name, String version) =>
      exists(name, version);

  @override
  Stream<List<int>> download(String name, String version) {
    return _getTarballFile(name, version).openRead();
  }

  /// Next to the final path, so that [commitUpstream] is a rename and a
  /// partial file is never served.
  @override
  Future<File> upstreamTemporaryFile(String name, String version) async {
    final file = _inBaseDir(path.join('upstream', name, '$name-$version'));
    await file.parent.create(recursive: true);
    final stamp = '$pid-${DateTime.now().microsecondsSinceEpoch}';
    return File('${file.path}.tar.gz.$stamp.tmp');
  }

  /// Identical digests mean identical bytes, so an archive that is already
  /// there stays and [temporary] is dropped.
  @override
  Future<bool> commitUpstream(String name, String version, String digest,
      File temporary, int size) async {
    final target = _getUpstreamFile(name, version, digest);
    if (await target.exists()) {
      await temporary.delete();
      return true;
    }
    await _flushToDisk(temporary);
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
  Future<void> deleteUpstream(
      String name, String version, String digest) async {
    try {
      await _getUpstreamFile(name, version, digest).delete();
    } on PathNotFoundException {
      // Never kept, or another instance got there first.
    }
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
