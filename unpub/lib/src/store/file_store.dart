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
  File _getTarballFile(String name, String version) {
    final base = path.normalize(path.absolute(baseDir));
    final relative =
        getFilePath?.call(name, version) ?? '$name-$version.tar.gz';
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
  Stream<List<int>> download(String name, String version) {
    return _getTarballFile(name, version).openRead();
  }

  /// Verifies [baseDir] exists and is writable by writing a probe file.
  @override
  Future<void> checkHealth() async {
    await Directory(baseDir).create(recursive: true);
    final stamp = '$pid-${DateTime.now().microsecondsSinceEpoch}';
    final probe = File(path.join(baseDir, '.unpub-health-$stamp'));
    await probe.writeAsString('ok');
    await probe.delete();
  }
}
