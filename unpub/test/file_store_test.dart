import 'dart:io';

import 'package:async/async.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:logging/logging.dart';
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

  group('published objects', () {
    const data = [1, 2, 3];
    final digest = digestOf(data);
    File objectFile(Directory baseDir) =>
        File(path.join(baseDir.path, 'foo', 'foo-1.0.0-$digest.tar.gz'));
    File legacyFile(Directory baseDir) =>
        File(path.join(baseDir.path, 'foo-1.0.0.tar.gz'));
    List<FileSystemEntity> temporaries(Directory baseDir) {
      var directory = Directory(path.join(baseDir.path, '.unpub-tmp'));
      return directory.existsSync() ? directory.listSync() : const [];
    }

    test('are named by their digest, and not at the legacy path', () async {
      var baseDir = setupFixture('object-layout');
      var store = unpub.FileStore(baseDir.path);
      await store.storeObject('foo', '1.0.0', digest, data);
      expect(objectFile(baseDir).readAsBytesSync(), data);
      expect(legacyFile(baseDir).existsSync(), isFalse);
      expect(temporaries(baseDir), isEmpty);
    });

    test('read back and report what is stored', () async {
      var store = unpub.FileStore(setupFixture('object-read').path);
      expect(await store.objectExists('foo', '1.0.0', digest), isFalse);
      await store.storeObject('foo', '1.0.0', digest, data);
      expect(await store.objectExists('foo', '1.0.0', digest), isTrue);
      expect(await collectBytes(store.downloadObject('foo', '1.0.0', digest)),
          data);
    });

    test('of one version with different bytes live side by side', () async {
      var store = unpub.FileStore(setupFixture('object-two').path);
      await store.storeObject('foo', '1.0.0', digest, data);
      await store.storeObject('foo', '1.0.0', digestOf([4]), [4]);
      expect(await collectBytes(store.downloadObject('foo', '1.0.0', digest)),
          data);
      expect(
          await collectBytes(
              store.downloadObject('foo', '1.0.0', digestOf([4]))),
          [4]);
    });

    test('storing a digest again keeps the file, and makes it count as new',
        () async {
      var baseDir = setupFixture('object-repeat');
      var store = unpub.FileStore(baseDir.path);
      await store.storeObject('foo', '1.0.0', digest, data);
      var file = objectFile(baseDir);
      file.setLastModifiedSync(DateTime.now().subtract(_hourAndABit));

      await store.storeObject('foo', '1.0.0', digest, data);

      expect(file.readAsBytesSync(), data);
      expect(file.lastModifiedSync().difference(DateTime.now()).inMinutes.abs(),
          lessThan(1));
      expect(temporaries(baseDir), isEmpty);
    });

    test('a failed write leaves no temporary file', () async {
      var baseDir = setupFixture('object-failure');
      File(path.join(baseDir.path, 'foo')).writeAsStringSync('in the way');
      var store = unpub.FileStore(baseDir.path);
      await expectLater(store.storeObject('foo', '1.0.0', digest, data),
          throwsA(isA<FileSystemException>()));
      expect(temporaries(baseDir), isEmpty);
    });

    test('deleting is safe to repeat', () async {
      var baseDir = setupFixture('object-delete');
      var store = unpub.FileStore(baseDir.path);
      await store.deleteObject('foo', '1.0.0', digest);
      await store.storeObject('foo', '1.0.0', digest, data);
      await store.deleteObject('foo', '1.0.0', digest);
      await store.deleteObject('foo', '1.0.0', digest);
      expect(objectFile(baseDir).existsSync(), isFalse);
    });

    test('use getObjectPath, and getFilePath only for the legacy path',
        () async {
      var baseDir = setupFixture('object-custom');
      var store = unpub.FileStore(baseDir.path,
          getFilePath: newFilePathFunc(),
          getObjectPath: (name, version, sha) => 'objects/$sha.bin');
      await store.storeObject('foo', '1.0.0', digest, data);
      expect(
          File(path.join(baseDir.path, 'objects', '$digest.bin')).existsSync(),
          isTrue);
      expect(await store.exists('foo', '1.0.0'), isFalse);
      await store.upload('foo', '1.0.0', [9]);
      expect(await collectBytes(store.download('foo', '1.0.0')), [9]);
      expect(await collectBytes(store.downloadObject('foo', '1.0.0', digest)),
          data);
    });

    for (var bad in ['abc', 'A' * 64, '../${'a' * 61}']) {
      test('refuse "$bad" as a digest', () async {
        var store = unpub.FileStore(setupFixture('object-digest').path);
        await expectLater(
            store.storeObject('foo', '1.0.0', bad, data), throwsArgumentError);
      });
    }

    test('a store with only upload writes to the legacy path', () async {
      var store = _UploadOnlyStore();
      await store.storeObject('foo', '1.0.0', digest, data);
      expect(store.uploaded, ['foo@1.0.0']);
      await store.deleteObject('foo', '1.0.0', digest);
      expect(store.uploaded, ['foo@1.0.0']);
    });
  });

  group('the reserved temporary namespace', () {
    for (var reserved in [
      '.unpub-tmp/x.tar.gz',
      './.unpub-tmp/x.tar.gz',
      'a/../.unpub-tmp/x.tar.gz',
      '.UNPUB-TMP/x.tar.gz',
    ]) {
      test('a getFilePath in "$reserved" fails at startup', () {
        expect(() => unpub.FileStore('x', getFilePath: (_, __) => reserved),
            throwsArgumentError);
      });

      test('a getObjectPath in "$reserved" fails at startup', () {
        expect(
            () => unpub.FileStore('x', getObjectPath: (_, __, ___) => reserved),
            throwsArgumentError);
      });
    }

    test('a path that only reaches it for some names fails on use', () async {
      var store = unpub.FileStore(setupFixture('namespace-late').path,
          getFilePath: (name, version) =>
              name == 'tricky' ? '.unpub-tmp/$name.tar.gz' : '$name.tar.gz');
      await expectLater(store.upload('tricky', '1.0.0', testPackageData),
          throwsArgumentError);
      await store.upload('fine', '1.0.0', testPackageData);
    });

    test('a function that cannot handle the sample fails on use only',
        () async {
      var store = unpub.FileStore(setupFixture('namespace-sample').path,
          getFilePath: (name, version) {
        if (name != 'expected') throw StateError('unknown package');
        return 'expected.tar.gz';
      });
      await store.upload('expected', '1.0.0', testPackageData);
    });
  });

  group('reclaiming temporary files', () {
    late Directory baseDir;
    late unpub.FileStore store;

    setUp(() {
      baseDir = setupFixture('reclaim');
      store = unpub.FileStore(baseDir.path);
    });

    test('deletes old files in the namespace, whatever they are called',
        () async {
      var spool = _temporaryFile(baseDir, '.unpub-tmp/1-2-3.tmp');
      var zip = _temporaryFile(baseDir, '.unpub-tmp/foo-1.0.0.zip');
      var nested = _temporaryFile(baseDir, '.unpub-tmp/sub/part');

      expect(await store.reclaimTemporary(), 3);

      expect(spool.existsSync(), isFalse);
      expect(zip.existsSync(), isFalse);
      expect(nested.existsSync(), isFalse);
    });

    test('leaves a fresh temporary file alone', () async {
      var spool = _temporaryFile(baseDir, '.unpub-tmp/1-2-3.tmp', old: false);

      expect(await store.reclaimTemporary(), 0);

      expect(spool.existsSync(), isTrue);
    });

    for (var name in [
      'foo-1.0.0.tar.gz',
      'packages/f/fo/foo/versions/foo-1.0.0.tar.gz.abc123.staging',
      'foo-1.0.0.tar.gz.abc123.staging',
      'upstream/foo/foo-1.0.0-${'a' * 64}.tar.gz',
      'upstream/foo/foo-1.0.0.tar.gz.123-456.tmp',
      'foo/foo-1.0.0-${'a' * 64}.tar.gz',
      'custom/foo-1.0.0.zip',
      'notes.tmp',
      'other.staging',
      '.unpub-health-1-2',
    ]) {
      test('never deletes $name, however old', () async {
        var file = _temporaryFile(baseDir, name);
        expect(await store.reclaimTemporary(), 0);
        expect(file.existsSync(), isTrue);
      });
    }

    test('tolerates a missing storage directory', () async {
      expect(
          await unpub.FileStore(path.join(baseDir.path, 'missing'))
              .reclaimTemporary(),
          0);
    });

    test('the default clears only its namespace in the system temp', () async {
      var store = _UploadOnlyStore();
      var namespace =
          Directory(path.join(Directory.systemTemp.path, '.unpub-tmp'))
            ..createSync();
      var stamp = DateTime.now().microsecondsSinceEpoch;
      var old = File(path.join(namespace.path, 'old-$stamp.tmp'))
        ..writeAsStringSync('x')
        ..setLastModifiedSync(DateTime.now().subtract(_hourAndABit));
      var fresh = File(path.join(namespace.path, 'fresh-$stamp.tmp'))
        ..writeAsStringSync('x');
      var outside = File(path.join(
          Directory.systemTemp.path, 'unpub-upstream-${pid + 1}-7-$stamp.tmp'))
        ..writeAsStringSync('x')
        ..setLastModifiedSync(DateTime.now().subtract(_hourAndABit));
      addTearDown(() {
        for (var file in [old, fresh, outside]) {
          if (file.existsSync()) file.deleteSync();
        }
      });

      expect(await store.reclaimTemporary(), greaterThanOrEqualTo(1));

      expect(old.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
      expect(outside.existsSync(), isTrue);
    });

    group('on a schedule', () {
      test('runs at startup, then on the interval, and logs a count', () async {
        var records = <LogRecord>[];
        var previous = Logger.root.level;
        Logger.root.level = Level.ALL;
        var subscription = Logger('unpub.reclaim').onRecord.listen(records.add);
        addTearDown(() async {
          Logger.root.level = previous;
          await subscription.cancel();
        });

        var first = _temporaryFile(baseDir, '.unpub-tmp/1.tmp');
        var reclaimer = unpub.TemporaryReclaimer(store,
            interval: const Duration(milliseconds: 50))
          ..start();
        addTearDown(reclaimer.stop);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(first.existsSync(), isFalse);

        var second = _temporaryFile(baseDir, '.unpub-tmp/2.tmp');
        for (var i = 0; i < 100 && second.existsSync(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(second.existsSync(), isFalse);
        expect(records.map((r) => r.message),
            everyElement(contains('reclaimed temporary files')));
        expect(records, hasLength(2));

        reclaimer.stop();
        var third = _temporaryFile(baseDir, '.unpub-tmp/3.tmp');
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(third.existsSync(), isTrue);
      });

      test('a failing store is only logged', () async {
        expect(await unpub.TemporaryReclaimer(_FailingReclaimStore()).run(), 0);
      });
    });
  });

  group('reclaiming orphan objects', () {
    const data = [1, 2, 3];
    final digest = digestOf(data);
    late Directory baseDir;
    late unpub.FileStore store;

    File objectAt(String relative, {List<int> bytes = data, bool old = true}) {
      var file = File(path.join(baseDir.path, relative))
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes);
      if (old) file.setLastModifiedSync(DateTime.now().subtract(_hourAndABit));
      return file;
    }

    Future<int> reclaim(unpub.PackageStore store, Set<String> referenced) =>
        unpub.TemporaryReclaimer(store, references: _Held(referenced))
            .reclaimOrphans();

    setUp(() {
      baseDir = setupFixture('orphans');
      store = unpub.FileStore(baseDir.path);
    });

    test('deletes an old object nothing refers to', () async {
      var published = objectAt('foo/foo-1.0.0-$digest.tar.gz');
      var proxied = objectAt('upstream/foo/foo-1.0.0-$digest.tar.gz');

      expect(await reclaim(store, {}), 2);

      expect(published.existsSync(), isFalse);
      expect(proxied.existsSync(), isFalse);
    });

    test('keeps a referenced object', () async {
      var file = objectAt('foo/foo-1.0.0-$digest.tar.gz');
      expect(await reclaim(store, {digest}), 0);
      expect(file.existsSync(), isTrue);
    });

    test('keeps a fresh object', () async {
      var file = objectAt('foo/foo-1.0.0-$digest.tar.gz', old: false);
      expect(await reclaim(store, {}), 0);
      expect(file.existsSync(), isTrue);
    });

    test('keeps an object referenced since the listing was taken', () async {
      var file = objectAt('foo/foo-1.0.0-$digest.tar.gz');
      expect(
          await unpub.TemporaryReclaimer(store, references: _LateHeld(digest))
              .reclaimOrphans(),
          0);
      expect(file.existsSync(), isTrue);
    });

    test('keeps an object written again since the listing was taken', () async {
      var file = objectAt('foo/foo-1.0.0-$digest.tar.gz');
      expect(await reclaim(_StaleListingStore(baseDir.path, file), {}), 0);
      expect(file.existsSync(), isTrue);
    });

    test('keeps a file that only looks like an object', () async {
      var legacy = objectAt('foo/foo-1.0.0-$digest.tar.gz', bytes: [9]);
      expect(await reclaim(store, {}), 0);
      expect(legacy.existsSync(), isTrue);
    });

    for (var name in [
      'foo-1.0.0.tar.gz',
      'custom/layout/foo-1.0.0.tar.gz',
      'foo/foo-1.0.0-${'a' * 63}.tar.gz',
      'foo/bar-1.0.0-${'a' * 64}.tar.gz',
      'foo/foo-1.0.0-${'A' * 64}.tar.gz',
      'a/foo/foo-1.0.0-${'a' * 64}.tar.gz',
      '.unpub-tmp/foo/foo-1.0.0-${'a' * 64}.tar.gz',
    ]) {
      test('never touches $name, however old', () async {
        var file = objectAt(name);
        expect(await reclaim(store, {}), 0);
        expect(file.existsSync(), isTrue);
      });
    }

    test('with a custom getObjectPath, looks only at upstream/', () async {
      var custom = unpub.FileStore(baseDir.path,
          getObjectPath: (name, version, sha) => 'objects/$sha');
      var local = objectAt('foo/foo-1.0.0-$digest.tar.gz');
      var inCustom = objectAt('objects/$digest');
      var proxied = objectAt('upstream/foo/foo-1.0.0-$digest.tar.gz');

      expect(await reclaim(custom, {}), 1);

      expect(local.existsSync(), isTrue);
      expect(inCustom.existsSync(), isTrue);
      expect(proxied.existsSync(), isFalse);
    });

    test('a store with the defaults has no objects to look at', () async {
      expect(await reclaim(_UploadOnlyStore(), {}), 0);
    });

    test('leaves everything alone without references', () async {
      var file = objectAt('foo/foo-1.0.0-$digest.tar.gz');
      expect(await unpub.TemporaryReclaimer(store).reclaimOrphans(), 0);
      expect(file.existsSync(), isTrue);
    });

    test('tolerates a missing storage directory', () async {
      expect(
          await reclaim(
              unpub.FileStore(path.join(baseDir.path, 'missing')), {}),
          0);
    });

    test('one that cannot be read does not stop the others', () async {
      var first = objectAt('foo/foo-1.0.0-$digest.tar.gz');
      var second = objectAt('bar/bar-1.0.0-$digest.tar.gz');
      expect(await reclaim(_UnreadableStore(baseDir.path, 'foo'), {}), 1);
      expect(first.existsSync(), isTrue);
      expect(second.existsSync(), isFalse);
    });

    test('a run logs the count of each kind', () async {
      var records = <LogRecord>[];
      var previous = Logger.root.level;
      Logger.root.level = Level.ALL;
      var subscription = Logger('unpub.reclaim').onRecord.listen(records.add);
      addTearDown(() async {
        Logger.root.level = previous;
        await subscription.cancel();
      });
      objectAt('foo/foo-1.0.0-$digest.tar.gz');
      _temporaryFile(baseDir, '.unpub-tmp/1.tmp');

      var count =
          await unpub.TemporaryReclaimer(store, references: _Held({})).run();

      expect(count, 2);
      expect(records.map((r) => r.message.toString()), [
        contains('reclaimed temporary files'),
        contains('reclaimed orphan objects'),
      ]);
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
      var kept = File(path.join(
          baseDir.path, 'upstream', 'foo', 'foo-1.0.0-$digest.tar.gz'));
      final stamp = DateTime.now().subtract(const Duration(days: 1));
      kept.setLastModifiedSync(stamp);

      await cacheUpstream(store, 'foo', '1.0.0', data);

      expect(kept.parent.listSync(), hasLength(1));
      expect(kept.lastModifiedSync().difference(stamp).inSeconds.abs(),
          lessThan(5),
          reason: 'the object that was already there is left as it is');
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

    test('the temporary file is in the reserved namespace', () async {
      var baseDir = setupFixture('upstream-temporary');
      var store = unpub.FileStore(baseDir.path);
      var temporary = await store.upstreamTemporaryFile('foo', '1.0.0');
      expect(path.dirname(path.absolute(temporary.path)),
          path.join(path.absolute(baseDir.path), '.unpub-tmp'));
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

const _hourAndABit = Duration(hours: 1, minutes: 5);

File _temporaryFile(Directory baseDir, String relative, {bool old = true}) {
  var file = File(path.join(baseDir.path, relative))
    ..createSync(recursive: true)
    ..writeAsStringSync('partial');
  if (old) file.setLastModifiedSync(DateTime.now().subtract(_hourAndABit));
  return file;
}

class _Held implements unpub.ArchiveReferences {
  final Set<String> held;

  const _Held(this.held);

  @override
  Future<Set<String>> digests() async => held;

  @override
  Future<bool> isReferenced(String digest) async => held.contains(digest);
}

/// Reports nothing in the listing, and [digest] when asked about it.
class _LateHeld implements unpub.ArchiveReferences {
  final String digest;

  const _LateHeld(this.digest);

  @override
  Future<Set<String>> digests() async => const {};

  @override
  Future<bool> isReferenced(String candidate) async => candidate == digest;
}

/// Lists a file as old, though it has just been written again.
class _StaleListingStore extends unpub.FileStore {
  final File file;

  _StaleListingStore(super.baseDir, this.file);

  @override
  Future<List<unpub.StoredObject>> listObjects() async {
    final objects = await super.listObjects();
    file.setLastModifiedSync(DateTime.now());
    return objects;
  }
}

class _UnreadableStore extends unpub.FileStore {
  final String unreadable;

  _UnreadableStore(super.baseDir, this.unreadable);

  @override
  Stream<List<int>> readObject(unpub.StoredObject object) =>
      object.name == unreadable
          ? Stream.error(const FileSystemException('no access'))
          : super.readObject(object);
}

class _FailingReclaimStore extends unpub.PackageStore {
  @override
  Future<void> upload(String name, String version, List<int> content) async {}

  @override
  Future<int> reclaimTemporary(
          {DateTime? now, Duration maxAge = unpub.temporaryFileMaxAge}) =>
      throw const FileSystemException('no access');
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
