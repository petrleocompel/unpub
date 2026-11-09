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

  /// A proxied archive, under `upstream/`. A locally published archive never
  /// lands there, whatever the name, because it has no directory of its own.
  File _getUpstreamFile(String name, String version) =>
      _inBaseDir(path.join('upstream', name, '$name-$version.tar.gz'));

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

  @override
  Stream<List<int>> download(String name, String version) {
    return _getTarballFile(name, version).openRead();
  }

  /// Writes to a temporary name first, so that a partial file is never served.
  @override
  Future<void> cacheUpstream(
      String name, String version, List<int> content) async {
    final file = _getUpstreamFile(name, version);
    await file.parent.create(recursive: true);
    final stamp = '$pid-${DateTime.now().microsecondsSinceEpoch}';
    final temporary = File('${file.path}.$stamp.tmp');
    try {
      await temporary.writeAsBytes(content, flush: true);
      await temporary.rename(file.path);
    } catch (_) {
      await temporary.delete().catchError((Object _) => temporary);
      rethrow;
    }
  }

  @override
  Future<bool> upstreamCached(String name, String version) =>
      _getUpstreamFile(name, version).exists();

  @override
  Stream<List<int>> downloadUpstream(String name, String version) =>
      _getUpstreamFile(name, version).openRead();

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
