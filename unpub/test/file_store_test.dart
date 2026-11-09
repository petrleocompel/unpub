import 'dart:io';

import 'package:async/async.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as path;
import 'package:test/test.dart';
import 'package:unpub/unpub.dart' as unpub;

// test gzip data
const testPackageData = [
  0x8b, 0x1f, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x03, //
  0x02, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 //
];

String digestOf(List<int> data) => crypto.sha256.convert(data).toString();

Future<void> cacheUpstream(unpub.PackageStore store, String name,
    String version, List<int> data) async {
  final temporary = await store.upstreamTemporaryFile(name, version);
  await temporary.writeAsBytes(data);
  expect(
      await store.commitUpstream(
          name, version, digestOf(data), temporary, data.length),
      isTrue);
}

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

  test('exists reflects the stored archives', () async {
    var baseDir = setupFixture('exists');
    var store = unpub.FileStore(baseDir.path);
    expect(await store.exists('test_package', '1.0.0'), isFalse);
    await store.upload('test_package', '1.0.0', testPackageData);
    expect(await store.exists('test_package', '1.0.0'), isTrue);
  });

  group('stays inside its directory', () {
    test('a name cannot climb out', () async {
      var baseDir = setupFixture('traversal-name');
      var store = unpub.FileStore(baseDir.path);
      await expectLater(store.upload('../../escaped', '1.0.0', testPackageData),
          throwsA(isA<ArgumentError>()));
      expect(() => store.download('../../escaped', '1.0.0'),
          throwsA(isA<ArgumentError>()));
      expect(
          File(path.join(baseDir.parent.parent.path, 'escaped-1.0.0.tar.gz'))
              .existsSync(),
          isFalse);
    });

    for (var escaped in ['../escaped.tar.gz', '/tmp/escaped.tar.gz', '.']) {
      test('a custom path of "$escaped" is rejected', () async {
        var baseDir = setupFixture('traversal-custom');
        var store =
            unpub.FileStore(baseDir.path, getFilePath: (_, __) => escaped);
        await expectLater(
            store.upload('test_package', '1.0.0', testPackageData),
            throwsA(isA<ArgumentError>()));
      });
    }

    test('works with a relative base directory', () async {
      var baseDir = setupFixture('traversal-relative');
      var store = unpub.FileStore(path.relative(baseDir.path));
      await store.upload('test_package', '1.0.0', testPackageData);
      expect(await collectBytes(store.download('test_package', '1.0.0')),
          testPackageData);
    });
  });

  group('createBaseDir', () {
    test('creates a missing directory once', () async {
      var baseDir = setupFixture('create-base-dir');
      var nested = path.join(baseDir.path, 'missing', 'packages');
      var store = unpub.FileStore(nested);
      expect(await store.createBaseDir(), isTrue);
      expect(Directory(nested).existsSync(), isTrue);
      expect(await store.createBaseDir(), isFalse);
    });
  });

  group('checkHealth', () {
    test('passes and leaves nothing behind', () async {
      var baseDir = setupFixture('health-ok');
      await unpub.FileStore(baseDir.path).checkHealth();
      expect(baseDir.listSync(), isEmpty);
    });

    test('fails for a missing directory without creating it', () async {
      var baseDir = setupFixture('health-missing');
      var typo = Directory(path.join(baseDir.path, 'missing', 'packages'));
      await expectLater(unpub.FileStore(typo.path).checkHealth(),
          throwsA(isA<FileSystemException>()));
      expect(typo.parent.existsSync(), isFalse);
    });

    test('fails when the directory is not writable', () async {
      var baseDir = setupFixture('health-read-only');
      await Process.run('chmod', ['555', baseDir.path]);
      addTearDown(() => Process.run('chmod', ['755', baseDir.path]));
      await expectLater(unpub.FileStore(baseDir.path).checkHealth(),
          throwsA(isA<FileSystemException>()));
    }, skip: Platform.isWindows ? 'needs POSIX permissions' : false);

    test('fails when the path cannot hold a directory', () async {
      var baseDir = setupFixture('health-blocked');
      var blocker = File(path.join(baseDir.path, 'file'))..createSync();
      expect(unpub.FileStore(blocker.path).checkHealth(),
          throwsA(isA<FileSystemException>()));
    });
  });

  group('staging a publish', () {
    File finalFile(Directory baseDir) =>
        File(path.join(baseDir.path, 'foo-1.0.0.tar.gz'));
    File stagedFile(Directory baseDir, [String id = 'r1']) =>
        File(path.join(baseDir.path, 'foo-1.0.0.tar.gz.$id.staging'));

    test('stages next to the final path without publishing', () async {
      var baseDir = setupFixture('stage-next');
      var store = unpub.FileStore(baseDir.path);
      await store.stageArchive('foo', '1.0.0', 'r1', [1, 2]);
      expect(stagedFile(baseDir).readAsBytesSync(), [1, 2]);
      expect(finalFile(baseDir).existsSync(), isFalse);
      expect(await store.exists('foo', '1.0.0'), isFalse);
    });

    test('commit moves it to the legacy path and leaves nothing', () async {
      var baseDir = setupFixture('stage-commit');
      var store = unpub.FileStore(baseDir.path);
      await store.stageArchive('foo', '1.0.0', 'r1', [1, 2]);
      await store.commitStaged('foo', '1.0.0', 'r1');
      expect(finalFile(baseDir).readAsBytesSync(), [1, 2]);
      expect(baseDir.listSync(), hasLength(1));
    });

    test('commit never overwrites unless replacing', () async {
      var baseDir = setupFixture('stage-conflict');
      var store = unpub.FileStore(baseDir.path);
      await store.upload('foo', '1.0.0', [9]);
      await store.stageArchive('foo', '1.0.0', 'r1', [1, 2]);
      expect(await store.hasCommittedArchive('foo', '1.0.0'), isTrue);

      await expectLater(store.commitStaged('foo', '1.0.0', 'r1'),
          throwsA(isA<unpub.ArchiveExistsException>()));
      expect(finalFile(baseDir).readAsBytesSync(), [9]);

      await store.commitStaged('foo', '1.0.0', 'r1', replace: true);
      expect(finalFile(baseDir).readAsBytesSync(), [1, 2]);
    });

    test('discarding is safe to repeat', () async {
      var baseDir = setupFixture('stage-discard');
      var store = unpub.FileStore(baseDir.path);
      await store.discardStaged('foo', '1.0.0', 'r1');
      await store.stageArchive('foo', '1.0.0', 'r1', [1]);
      await store.discardStaged('foo', '1.0.0', 'r1');
      await store.discardStaged('foo', '1.0.0', 'r1');
      expect(baseDir.listSync(), isEmpty);
    });

    test('two attempts at one version stage separately', () async {
      var baseDir = setupFixture('stage-two');
      var store = unpub.FileStore(baseDir.path);
      await store.stageArchive('foo', '1.0.0', 'r1', [1]);
      await store.stageArchive('foo', '1.0.0', 'r2', [2]);
      expect(stagedFile(baseDir, 'r1').readAsBytesSync(), [1]);
      expect(stagedFile(baseDir, 'r2').readAsBytesSync(), [2]);
    });

    test('works with a custom layout', () async {
      var baseDir = setupFixture('stage-custom');
      var store = unpub.FileStore(baseDir.path, getFilePath: newFilePathFunc());
      await store.stageArchive('test_package', '1.0.0', 'r1', [1]);
      await store.commitStaged('test_package', '1.0.0', 'r1');
      expect(await collectBytes(store.download('test_package', '1.0.0')), [1]);
    });

    for (var unsafe in ['', '../x', 'a/b', 'a.b']) {
      test('refuses "$unsafe" as a staging id', () async {
        var store = unpub.FileStore(setupFixture('stage-id').path);
        await expectLater(store.stageArchive('foo', '1.0.0', unsafe, [1]),
            throwsArgumentError);
      });
    }

    test('a store with only upload publishes at commit', () async {
      var store = _UploadOnlyStore();
      await store.stageArchive('foo', '1.0.0', 'r1', [1]);
      expect(store.uploaded, isEmpty);
      await store.commitStaged('foo', '1.0.0', 'r1');
      expect(store.uploaded, ['foo@1.0.0']);
      expect(await store.hasCommittedArchive('foo', '1.0.0'), isFalse);

      await store.stageArchive('foo', '2.0.0', 'r2', [1]);
      await store.discardStaged('foo', '2.0.0', 'r2');
      await expectLater(
          store.commitStaged('foo', '2.0.0', 'r2'), throwsStateError);
    });
  });

  group('upstream namespace', () {
    const data = [1, 2, 3];
    final digest = digestOf(data);

    test('is under upstream/<name>/, named by the digest', () async {
      var baseDir = setupFixture('upstream-layout');
      var store = unpub.FileStore(baseDir.path);
      await cacheUpstream(store, 'foo', '1.0.0+1', data);
      expect(
          File(path.join(baseDir.path, 'upstream', 'foo',
                  'foo-1.0.0+1-$digest.tar.gz'))
              .readAsBytesSync(),
          data);
    });

    test('reads back and reports what is cached', () async {
      var store = unpub.FileStore(setupFixture('upstream-read').path);
      expect(await store.upstreamCached('foo', '1.0.0', digest), isFalse);
      await cacheUpstream(store, 'foo', '1.0.0', data);
      expect(await store.upstreamCached('foo', '1.0.0', digest), isTrue);
      expect(
          await store
              .downloadUpstream('foo', '1.0.0', digest)
              .expand((b) => b)
              .toList(),
          data);
    });

    test('keeps different bytes of one version side by side', () async {
      var store = unpub.FileStore(setupFixture('upstream-two').path);
      await cacheUpstream(store, 'foo', '1.0.0', data);
      await cacheUpstream(store, 'foo', '1.0.0', [4, 5]);
      expect(await collectBytes(store.downloadUpstream('foo', '1.0.0', digest)),
          data);
      expect(
          await collectBytes(
              store.downloadUpstream('foo', '1.0.0', digestOf([4, 5]))),
          [4, 5]);
    });

    test('drops the temporary file when the digest is already kept', () async {
      var baseDir = setupFixture('upstream-repeat');
      var store = unpub.FileStore(baseDir.path);
      await cacheUpstream(store, 'foo', '1.0.0', data);
      await cacheUpstream(store, 'foo', '1.0.0', data);
      expect(Directory(path.join(baseDir.path, 'upstream', 'foo')).listSync(),
          hasLength(1));
    });

    test('never serves a file at the mutable path of earlier commits',
        () async {
      var baseDir = setupFixture('upstream-legacy');
      var store = unpub.FileStore(baseDir.path);
      File(path.join(baseDir.path, 'upstream', 'foo', 'foo-1.0.0.tar.gz'))
        ..createSync(recursive: true)
        ..writeAsBytesSync([9]);
      expect(await store.upstreamCached('foo', '1.0.0', digest), isFalse);
      expect(
          await store.upstreamCached('foo', '1.0.0', digestOf([9])), isFalse);
    });

    for (var bad in ['abc', 'A' * 64, '../${'a' * 61}', 'g' * 64]) {
      test('refuses "$bad" as a digest', () {
        var store = unpub.FileStore(setupFixture('upstream-digest').path);
        expect(() => store.upstreamCached('foo', '1.0.0', bad),
            throwsArgumentError);
      });
    }

    test('is apart from published archives, even a custom layout', () async {
      var baseDir = setupFixture('upstream-apart');
      var store = unpub.FileStore(baseDir.path, getFilePath: newFilePathFunc());
      await cacheUpstream(store, 'foo', '1.0.0', data);
      expect(await store.exists('foo', '1.0.0'), isFalse);
      await store.upload('upstream', '1.0.0', [9]);
      expect(await store.exists('upstream', '1.0.0'), isTrue);
      expect(await store.upstreamCached('upstream', '1.0.0', digest), isFalse);
    });

    test('leaves no temporary file behind', () async {
      var baseDir = setupFixture('upstream-clean');
      await cacheUpstream(unpub.FileStore(baseDir.path), 'foo', '1.0.0', data);
      expect(Directory(path.join(baseDir.path, 'upstream', 'foo')).listSync(),
          hasLength(1));
    });

    test('the temporary file is next to the final path', () async {
      var baseDir = setupFixture('upstream-temporary');
      var store = unpub.FileStore(baseDir.path);
      var temporary = await store.upstreamTemporaryFile('foo', '1.0.0');
      expect(path.dirname(temporary.path),
          path.join(path.absolute(baseDir.path), 'upstream', 'foo'));
      expect(await store.upstreamCached('foo', '1.0.0', digest), isFalse);
    });

    test('forgets a cached archive, and tolerates a missing one', () async {
      var store = unpub.FileStore(setupFixture('upstream-delete').path);
      await store.deleteUpstream('foo', '1.0.0', digest);
      await cacheUpstream(store, 'foo', '1.0.0', data);
      await store.deleteUpstream('foo', '1.0.0', digest);
      expect(await store.upstreamCached('foo', '1.0.0', digest), isFalse);
    });

    test('rejects a name that would escape the directory', () async {
      var store = unpub.FileStore(setupFixture('upstream-escape').path);
      expect(() => store.upstreamCached('../../x', '1.0.0', digest),
          throwsArgumentError);
    });
  });
}

class _UploadOnlyStore extends unpub.PackageStore {
  final uploaded = <String>[];

  @override
  Future<void> upload(String name, String version, List<int> content) async {
    uploaded.add('$name@$version');
  }
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
