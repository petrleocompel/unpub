import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:mongo_dart/mongo_dart.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';
import 'package:unpub/unpub.dart';

import 'utils.dart';

const _timeout = Timeout(Duration(minutes: 3));

void main() {
  late Db db;
  HttpServer? running;

  Future<void> serve(PublishConfig publish,
      {Future<void> Function(Map<String, dynamic>, String)? validator}) async {
    await running?.close();
    running = await createServer(email0,
        publish: publish, uploadValidator: validator);
  }

  void expectPublished(ProcessResult result) =>
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');

  void expectRefused(ProcessResult result, String message) {
    expect(result.exitCode, isNot(0), reason: '${result.stdout}');
    expect(result.stderr, contains(message));
  }

  Future<List<Object?>> versionsOf(String name) async {
    final package =
        await db.collection(packageCollection).findOne(where.eq('name', name));
    return (package?['versions'] as List? ?? const [])
        .map((v) => v['version'])
        .toList();
  }

  setUpAll(() async {
    db = Db(testMongoUri);
    await db.open();
    await setUpPubClient();
  });

  tearDownAll(() async {
    await tearDownPubClient();
    await db.close();
  });

  setUp(() async {
    await db.dropCollection(packageCollection);
    await db.dropCollection(statsCollection);
  });

  tearDown(() async {
    await running?.close();
    running = null;
  });

  group('publish.allowedNamePrefixes', () {
    const policy = PublishConfig(allowedNamePrefixes: ['acme_', 'corp_']);

    test('accepts a listed prefix', () async {
      await serve(policy);
      expectPublished(await pubPublishGenerated('acme_tool', '1.0.0'));
    }, timeout: _timeout);

    test('refuses any other name', () async {
      await serve(policy);
      expectRefused(await pubPublishGenerated('other_tool', '1.0.0'),
          'publish.allowedNamePrefixes');
      expect(await versionsOf('other_tool'), isEmpty);
    }, timeout: _timeout);
  });

  group('publish.maxArchiveBytes', () {
    test('accepts an archive within the limit', () async {
      await serve(const PublishConfig(maxArchiveBytes: 1024 * 1024));
      expectPublished(await pubPublishGenerated('sized', '1.0.0'));
    }, timeout: _timeout);

    test('refuses a larger archive', () async {
      await serve(const PublishConfig(maxArchiveBytes: 10));
      expectRefused(await pubPublishGenerated('sized', '1.0.0'),
          'publish.maxArchiveBytes');
      expect(await versionsOf('sized'), isEmpty);
    }, timeout: _timeout);
  });

  group('publish.maxUnpackedBytes', () {
    late List<int> bomb;

    setUpAll(() {
      bomb = GZipEncoder().encodeBytes(Uint8List(32 * 1024 * 1024));
    });

    App buildApp(int limit) => App(
          metaStore: MongoStore(db),
          packageStore: FileStore(Directory.systemTemp.path),
          authenticator: const FakeAuthenticator(testToken, 'dev@b.c'),
          publishPolicy: PublishPolicy(PublishConfig(maxUnpackedBytes: limit)),
        );

    Archive archiveWithPadding(int padding) => Archive()
      ..addFile(ArchiveFile.string(
          'pubspec.yaml', 'name: inflated\nversion: 1.0.0\n'))
      ..addFile(ArchiveFile.bytes('padding.bin', Uint8List(padding)));

    Future<String?> uploadError(App app, Archive archive) async {
      final response = await app.handler(uploadRequestOf(
          archive, const {'authorization': 'Bearer $testToken'}));
      return Uri.parse(response.headers['location']!).queryParameters['error'];
    }

    test('stops a compression bomb at the limit', () {
      const limit = 1024 * 1024;
      expect(bomb.length, lessThan(1024 * 1024));
      expect(
          () => const PublishPolicy(PublishConfig(maxUnpackedBytes: limit))
              .inflate(bomb),
          throwsA(isA<PublishPolicyViolation>().having(
              (violation) => violation.message,
              'message',
              allOf(
                  contains('publish.maxUnpackedBytes'), contains('$limit')))));
    });

    test('inflates what fits', () {
      final inflated =
          const PublishPolicy(PublishConfig(maxUnpackedBytes: 32 * 1024 * 1024))
              .inflate(bomb);
      expect(inflated.length, 32 * 1024 * 1024);
    });

    test('an upload that unpacks past the limit is refused', () async {
      final error = await uploadError(
          buildApp(1024 * 1024), archiveWithPadding(4 * 1024 * 1024));

      expect(error, contains('publish.maxUnpackedBytes'));
      expect(await versionsOf('inflated'), isEmpty);
    });

    test('a corrupt archive is refused', () async {
      final response = await buildApp(1024 * 1024).handler(shelf.Request(
        'POST',
        Uri.parse('http://internal:4000/api/packages/versions/newUpload'),
        headers: const {
          'authorization': 'Bearer $testToken',
          'content-type': 'multipart/form-data; boundary=b',
        },
        body: utf8.encode('--b\r\n'
            'content-disposition: form-data; name="file"; filename="p.gz"\r\n'
            '\r\nnot gzip\r\n--b--\r\n'),
      ));
      expect(response.headers['location'], contains('error='));
    });

    test('the limit defaults to 512 MiB', () {
      expect(const PublishConfig().maxUnpackedBytes, 512 * 1024 * 1024);
    });
  });

  group('publish.requiredFiles', () {
    const policy = PublishConfig(requiredFiles: ['readme.md', 'CHANGELOG.md']);

    test('accepts an archive with the files, ignoring case', () async {
      await serve(policy);
      expectPublished(await pubPublishGenerated('documented', '1.0.0', files: {
        'README.md': '# Hello',
        'changelog.md': '## 1.0.0\n\n- First.\n',
      }));
    }, timeout: _timeout);

    test('refuses an archive without them', () async {
      await serve(policy);
      final result = await pubPublishGenerated('documented', '1.0.0',
          files: {'README.md': '# Hello'});
      expectRefused(result, 'publish.requiredFiles');
      expect(result.stderr, contains('CHANGELOG.md'));
      expect(result.stderr, isNot(contains('readme.md')));
      expect(await versionsOf('documented'), isEmpty);
    }, timeout: _timeout);

    test('only files at the archive root count', () {
      final policy =
          const PublishPolicy(PublishConfig(requiredFiles: ['NOTES.md']));
      policy.checkRequiredFiles(['./NOTES.md', 'pubspec.yaml']);
      expect(() => policy.checkRequiredFiles(['doc/NOTES.md']),
          throwsA(isA<PublishPolicyViolation>()));
    });
  });

  group('publish.rejectOlderThanLatest', () {
    const policy = PublishConfig(rejectOlderThanLatest: true);

    test('accepts a higher version', () async {
      await serve(policy);
      expectPublished(await pubPublishGenerated('ordered', '1.0.0'));
      expectPublished(await pubPublishGenerated('ordered', '1.1.0'));
    }, timeout: _timeout);

    test('refuses a lower version', () async {
      await serve(policy);
      expectPublished(await pubPublishGenerated('ordered', '2.0.0'));
      expectRefused(await pubPublishGenerated('ordered', '1.9.0'),
          'publish.rejectOlderThanLatest');
      expect(await versionsOf('ordered'), ['2.0.0']);
    }, timeout: _timeout);

    test('a retracted version does not count', () {
      final package = UnpubPackage(
        'ordered',
        [
          UnpubVersion(
              '1.0.0', const {}, null, null, null, null, DateTime.now()),
          UnpubVersion(
              '2.0.0', const {}, null, null, null, null, DateTime.now(),
              isRetracted: true),
        ],
        true,
        const [],
        DateTime.now(),
        DateTime.now(),
        0,
      );
      const PublishPolicy(PublishConfig(rejectOlderThanLatest: true))
          .checkVersion(package, '1.5.0');
    });
  });

  group('publish.requireVersionBump', () {
    test('a duplicate is refused by default with the existing message',
        () async {
      await serve(const PublishConfig());
      expectPublished(await pubPublishGenerated('bumped', '1.0.0'));
      final result = await pubPublishGenerated('bumped', '1.0.0');
      expectRefused(result, 'version invalid: bumped@1.0.0 already exists.');
      expect(result.stderr, contains('publish.requireVersionBump'));
      expect(await versionsOf('bumped'), ['1.0.0']);
    }, timeout: _timeout);

    test('when off, publishing again replaces the version', () async {
      await serve(const PublishConfig(requireVersionBump: false));
      expectPublished(await pubPublishGenerated('bumped', '1.0.0'));
      expectPublished(await pubPublishGenerated('bumped', '1.0.0',
          files: {'README.md': '# Changed'}));
      expect(await versionsOf('bumped'), ['1.0.0']);
      final package = await db
          .collection(packageCollection)
          .findOne(where.eq('name', 'bumped'));
      expect(package!['versions'][0]['readme'], '# Changed');
    }, timeout: _timeout);
  });

  group('uploadValidator', () {
    test('runs after the policies and can refuse', () async {
      final seen = <String>[];
      Future<void> validator(Map<String, dynamic> pubspec, String email) async {
        seen.add(pubspec['name'] as String);
        throw 'the callback said no';
      }

      await serve(const PublishConfig(allowedNamePrefixes: ['acme_']),
          validator: validator);

      expectRefused(await pubPublishGenerated('other_tool', '1.0.0'),
          'publish.allowedNamePrefixes');
      expect(seen, isEmpty);

      expectRefused(await pubPublishGenerated('acme_tool', '1.0.0'),
          'the callback said no');
      expect(seen, ['acme_tool']);
    }, timeout: _timeout);
  });
}
