import 'dart:io';

import 'package:async/async.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';
import 'package:unpub/unpub.dart' as unpub;

// test gzip data
const testPackageData = [
  0x8b, 0x1f, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x03, //
  0x02, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 //
];

void main() {
  test('upload-download-default-path', () async {
    var baseDir = setupFixture('upload-download-default-path');
    var store = unpub.FileStore(baseDir.path);
    await store.upload('test_package', '1.0.0', testPackageData);
    var pkg2 = await collectBytes(store.download('test_package', '1.0.0'));
    expect(pkg2, testPackageData);
    expect(
        File(path.join(baseDir.path, 'test_package-1.0.0.tar.gz')).existsSync(),
        isTrue);
  });

  test('upload-download-custom-path', () async {
    var baseDir = setupFixture('upload-download-custom-path');
    var store = unpub.FileStore(baseDir.path, getFilePath: newFilePathFunc());
    await store.upload('test_package', '1.0.0', testPackageData);
    var pkg2 = await collectBytes(store.download('test_package', '1.0.0'));
    expect(pkg2, testPackageData);
    expect(
        File(path.join(baseDir.path, 'packages', 't', 'te', 'test_package',
                'versions', 'test_package-1.0.0.tar.gz'))
            .existsSync(),
        isTrue);
  });

  group('checkHealth', () {
    test('creates the directory and leaves nothing behind', () async {
      var baseDir = setupFixture('health-create');
      var nested = Directory(path.join(baseDir.path, 'missing', 'packages'));
      await unpub.FileStore(nested.path).checkHealth();
      expect(nested.existsSync(), isTrue);
      expect(nested.listSync(), isEmpty);
    });

    test('fails when the path cannot hold a directory', () async {
      var baseDir = setupFixture('health-blocked');
      var blocker = File(path.join(baseDir.path, 'file'))..createSync();
      expect(unpub.FileStore(blocker.path).checkHealth(),
          throwsA(isA<FileSystemException>()));
    });
  });
}

String Function(String, String) newFilePathFunc() {
  return (String package, String version) {
    var grp = package[0];
    var subgrp = package.substring(0, 2);
    return path.join('packages', grp, subgrp, package, 'versions',
        '$package-$version.tar.gz');
  };
}

Directory setupFixture(final String name) {
  var baseDir =
      Directory(path.absolute('test', 'fixtures', 'file_store', name));
  if (baseDir.existsSync()) {
    baseDir.deleteSync(recursive: true);
  }
  baseDir.createSync();
  return baseDir;
}
