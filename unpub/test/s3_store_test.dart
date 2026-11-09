import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:minio/minio.dart';
import 'package:minio/models.dart' as s3;
import 'package:path/path.dart' as path;
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';
import 'package:unpub/unpub.dart';

/// `host:port` of an S3 compatible service for the integration tests.
final s3Endpoint = Platform.environment['UNPUB_TEST_S3_ENDPOINT'];
const s3Bucket = 'dart-pub-test';
final s3AccessKey =
    Platform.environment['UNPUB_TEST_S3_ACCESS_KEY'] ?? 'rustfsadmin';
final s3SecretKey =
    Platform.environment['UNPUB_TEST_S3_SECRET_KEY'] ?? 'rustfsadmin';

const mockCredentials =
    AwsCredentials(accessKeyId: 'key', secretAccessKey: 'secret');

void main() {
  group('aws credentials', () {
    test('explicit values win over the environment', () async {
      var credentials = await AwsCredentials.resolve(
        accessKeyId: 'specialKey',
        secretAccessKey: 'specialSecret',
        environment: {
          'AWS_ACCESS_KEY_ID': 'env-key',
          'AWS_SECRET_ACCESS_KEY': 'env-secret',
        },
      );
      expect(credentials.accessKeyId, 'specialKey');
      expect(credentials.secretAccessKey, 'specialSecret');
    });

    test('explicit keys ignore an ambient session token', () async {
      var credentials = await AwsCredentials.resolve(
        accessKeyId: 'specialKey',
        secretAccessKey: 'specialSecret',
        environment: {'AWS_SESSION_TOKEN': 'unrelated-session'},
      );
      expect(credentials.sessionToken, isNull);
    });

    test('explicit keys keep their own session token', () async {
      var credentials = await AwsCredentials.resolve(
        accessKeyId: 'specialKey',
        secretAccessKey: 'specialSecret',
        sessionToken: 'own-session',
        environment: {'AWS_SESSION_TOKEN': 'unrelated-session'},
      );
      expect(credentials.sessionToken, 'own-session');
    });

    for (var arguments in const [
      ('key', null, null),
      (null, 'secret', null),
      (null, null, 'token'),
    ]) {
      test('$arguments is incomplete and borrows nothing', () {
        expect(
          AwsCredentials.resolve(
            accessKeyId: arguments.$1,
            secretAccessKey: arguments.$2,
            sessionToken: arguments.$3,
            environment: {
              'AWS_ACCESS_KEY_ID': 'env-key',
              'AWS_SECRET_ACCESS_KEY': 'env-secret',
            },
          ),
          throwsA(isA<ArgumentError>()),
        );
      });
    }

    test('empty environment values count as missing', () {
      expect(
        AwsCredentials.resolve(environment: {
          'AWS_ACCESS_KEY_ID': '',
          'AWS_SECRET_ACCESS_KEY': '',
          'AWS_CONTAINER_CREDENTIALS_RELATIVE_URI': '',
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('read from the environment', () async {
      var credentials = await AwsCredentials.resolve(environment: {
        'AWS_ACCESS_KEY_ID': 'special-key-id',
        'AWS_SECRET_ACCESS_KEY': 'special-access-key',
        'AWS_SESSION_TOKEN': 'special-session',
      });
      expect(credentials.accessKeyId, 'special-key-id');
      expect(credentials.secretAccessKey, 'special-access-key');
      expect(credentials.sessionToken, 'special-session');
    });

    test('fetched from the ecs container endpoint', () async {
      late Uri requested;
      var client = MockClient((request) async {
        requested = request.url;
        return http.Response(
          json.encode({
            'AccessKeyId': 'container-creds-key',
            'SecretAccessKey': 'container-creds-secret',
            'Token': 'container-creds-token',
          }),
          200,
        );
      });

      var credentials = await AwsCredentials.resolve(
        environment: {'AWS_CONTAINER_CREDENTIALS_RELATIVE_URI': '/creds/1'},
        httpClient: client,
      );

      expect(requested.toString(), 'http://169.254.170.2/creds/1');
      expect(credentials.accessKeyId, 'container-creds-key');
      expect(credentials.secretAccessKey, 'container-creds-secret');
      expect(credentials.sessionToken, 'container-creds-token');
    });

    test('missing credentials are an error', () {
      expect(AwsCredentials.resolve(environment: {}),
          throwsA(isA<ArgumentError>()));
    });
  });

  group('region', () {
    test('taken from the argument', () {
      var store = S3Store(s3Bucket,
          region: 'us-east-1', credentials: mockCredentials, environment: {});
      expect(store.region, 'us-east-1');
    });

    test('taken from the environment', () {
      var store = S3Store(s3Bucket,
          credentials: mockCredentials,
          environment: {'AWS_DEFAULT_REGION': 'eu-west-1'});
      expect(store.region, 'eu-west-1');
    });

    test('is required', () {
      expect(
        () => S3Store(s3Bucket, credentials: mockCredentials, environment: {}),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message',
            'Could not determine a default region for aws.')),
      );
    });
  });

  group('checkHealth', () {
    test('writes and removes a probe under the reserved prefix', () async {
      var minio = FakeMinio();
      await S3Store(s3Bucket, minio: minio).checkHealth();
      expect(minio.written.single, startsWith('.unpub/readyz-'));
      expect(minio.removed, minio.written);
    });

    test('uses a new probe each time', () async {
      var minio = FakeMinio();
      var store = S3Store(s3Bucket, minio: minio);
      await store.checkHealth();
      await store.checkHealth();
      expect(minio.written.toSet(), hasLength(2));
    });

    test('fails when the bucket rejects writes', () async {
      var minio = FakeMinio()..putError = MinioError('Access Denied');
      await expectLater(
        S3Store(s3Bucket, minio: minio).checkHealth(),
        throwsA(isA<StateError>().having((e) => e.message, 'message',
            allOf(contains('write'), contains('Access Denied')))),
      );
    });

    test('fails when the bucket rejects deletes', () async {
      var minio = FakeMinio()..removeError = MinioError('Access Denied');
      await expectLater(
        S3Store(s3Bucket, minio: minio).checkHealth(),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('delete'))),
      );
    });

    test('a write failure is reported by readyz', () async {
      var app = App(
        metaStore: _HealthyMetaStore(),
        packageStore: S3Store(s3Bucket,
            minio: FakeMinio()..putError = MinioError('Access Denied')),
        authenticator: const StaticTokenAuthenticator(bootstrapToken: 'secret'),
      );
      var response = await app
          .handler(shelf.Request('GET', Uri.parse('http://localhost/readyz')));
      expect(response.statusCode, HttpStatus.serviceUnavailable);
      var checks = json.decode(await response.readAsString())['checks'];
      expect(checks['storage']['error'], contains('Access Denied'));
    });
  });

  group('committing a staged archive', () {
    test('quotes the copy source, in which a + would read as a space',
        () async {
      var minio = FakeMinio();
      await S3Store(s3Bucket, minio: minio)
          .commitStaged('fine', '1.0.0+1', 'r1', replace: true);
      expect(minio.copies.single, [
        'fine/fine-1.0.0+1.tar.gz',
        '/$s3Bucket/staging/fine/fine-1.0.0%2B1-r1.tar.gz',
      ]);
      expect(minio.removed.single, 'staging/fine/fine-1.0.0+1-r1.tar.gz');
    });

    test('a staged object that cannot be removed does not fail it', () async {
      var minio = FakeMinio()..removeError = MinioError('Access Denied');
      await S3Store(s3Bucket, minio: minio)
          .commitStaged('fine', '1.0.0', 'r1', replace: true);
      expect(minio.copies, hasLength(1));
    });
  });

  group('object keys', () {
    final store = S3Store(s3Bucket,
        region: 'us-east-1', credentials: mockCredentials, environment: {});

    for (var unsafe in [
      ['../escaped', '1.0.0'],
      ['a/b', '1.0.0'],
      ['fine', '../1.0.0'],
      ['fine', '1.0.0/x'],
      ['fine', '1.0.0\n'],
      ['fi\x00ne', '1.0.0'],
    ]) {
      test('rejects ${json.encode(unsafe)} before any request', () async {
        await expectLater(store.upload(unsafe[0], unsafe[1], testPackageData),
            throwsA(isA<ArgumentError>()));
        await expectLater(store.download(unsafe[0], unsafe[1]).drain<void>(),
            throwsA(isA<ArgumentError>()));
      });
    }

    for (var unsafe in ['', '../x', 'a/b']) {
      test('rejects "$unsafe" as a staging id', () async {
        await expectLater(
            store.discardStaged('fine', '1.0.0', unsafe), throwsArgumentError);
      });
    }

    test('rejects a digest that is not one', () async {
      await expectLater(
          store.upstreamCached('fine', '1.0.0', '../../${'a' * 58}'),
          throwsArgumentError);
    });

    for (var key in ['a/../b', 'a\x7fb']) {
      test('rejects a custom key of ${json.encode(key)}', () async {
        var custom = S3Store(s3Bucket,
            region: 'us-east-1',
            credentials: mockCredentials,
            environment: {},
            getObjectPath: (_, __) => key);
        await expectLater(custom.upload('fine', '1.0.0', testPackageData),
            throwsA(isA<ArgumentError>()));
      });
    }
  });

  group('against an s3 service', () {
    late Minio minio;

    setUpAll(() async {
      if (s3Endpoint == null) return;
      minio = createMinio(s3AccessKey, s3SecretKey);
      if (!await minio.bucketExists(s3Bucket)) {
        await minio.makeBucket(s3Bucket);
      }
    });

    test('upload and download with the default path', () async {
      var store = S3Store(s3Bucket, minio: minio);
      await store.upload('test_package', '1.0.0', testPackageData);
      expect(await collectBytes(store.download('test_package', '1.0.0')),
          testPackageData);

      var stat = await minio.statObject(
          s3Bucket, 'test_package/test_package-1.0.0.tar.gz');
      expect(stat.size, testPackageData.length);
    });

    test('a proxied archive lives under upstream/ on its own', () async {
      // The bucket outlives a test run.
      final name = 'proxied_${DateTime.now().microsecondsSinceEpoch}';
      var store = S3Store(s3Bucket, minio: minio);
      final digest = crypto.sha256.convert(testPackageData).toString();
      expect(await store.upstreamCached(name, '1.0.0', digest), isFalse);

      final temporary = await store.upstreamTemporaryFile(name, '1.0.0');
      addTearDown(() => temporary.delete());
      expect(path.dirname(temporary.path), Directory.systemTemp.path);
      await temporary.writeAsBytes(testPackageData);

      expect(
          await store.commitUpstream(
              name, '1.0.0', digest, temporary, testPackageData.length),
          isTrue);

      expect(await temporary.exists(), isTrue,
          reason: 'the caller deletes the temporary file');
      expect(await store.upstreamCached(name, '1.0.0', digest), isTrue);
      expect(await store.exists(name, '1.0.0'), isFalse);
      expect(await collectBytes(store.downloadUpstream(name, '1.0.0', digest)),
          testPackageData);
      var stat = await minio.statObject(
          s3Bucket, 'upstream/$name/$name-1.0.0-$digest.tar.gz');
      expect(stat.size, testPackageData.length);

      await store.deleteUpstream(name, '1.0.0', digest);
      expect(await store.upstreamCached(name, '1.0.0', digest), isFalse);
    });

    test('a staged publish is committed to the legacy key', () async {
      final name = 'staged_${DateTime.now().microsecondsSinceEpoch}';
      var store = S3Store(s3Bucket, minio: minio);

      await store.stageArchive(name, '1.0.0', 'r1', testPackageData);
      expect(await store.exists(name, '1.0.0'), isFalse);
      await minio.statObject(s3Bucket, 'staging/$name/$name-1.0.0-r1.tar.gz');

      await store.commitStaged(name, '1.0.0', 'r1');

      expect(
          await collectBytes(store.download(name, '1.0.0')), testPackageData);
      expect(await store.hasCommittedArchive(name, '1.0.0'), isTrue);
      await minio.statObject(s3Bucket, '$name/$name-1.0.0.tar.gz');
      var listed =
          await minio.listAllObjects(s3Bucket, prefix: 'staging/$name/');
      expect(listed.objects, isEmpty);
    });

    test('commit never overwrites unless replacing', () async {
      final name = 'staged_${DateTime.now().microsecondsSinceEpoch}';
      var store = S3Store(s3Bucket, minio: minio);
      await store.upload(name, '1.0.0', testPackageData);
      await store.stageArchive(name, '1.0.0', 'r1', testPackageData2);

      await expectLater(store.commitStaged(name, '1.0.0', 'r1'),
          throwsA(isA<ArchiveExistsException>()));
      expect(
          await collectBytes(store.download(name, '1.0.0')), testPackageData);

      await store.commitStaged(name, '1.0.0', 'r1', replace: true);
      expect(
          await collectBytes(store.download(name, '1.0.0')), testPackageData2);
    });

    test('discarding is safe to repeat', () async {
      final name = 'staged_${DateTime.now().microsecondsSinceEpoch}';
      var store = S3Store(s3Bucket, minio: minio);
      await store.discardStaged(name, '1.0.0', 'r1');
      await store.stageArchive(name, '1.0.0', 'r1', testPackageData);
      await store.discardStaged(name, '1.0.0', 'r1');
      await store.discardStaged(name, '1.0.0', 'r1');
      var listed =
          await minio.listAllObjects(s3Bucket, prefix: 'staging/$name/');
      expect(listed.objects, isEmpty);
    });

    test('exists reflects the stored objects', () async {
      var store = S3Store(s3Bucket, minio: minio);
      await store.upload('exists_package', '1.0.0', testPackageData);
      expect(await store.exists('exists_package', '1.0.0'), isTrue);
      expect(await store.exists('exists_package', '9.9.9'), isFalse);
    });

    test('exists surfaces failures other than not found', () async {
      var bad = createMinio('wrong-access-key', 'wrong-secret-key');
      expect(S3Store(s3Bucket, minio: bad).exists('exists_package', '1.0.0'),
          throwsA(isA<MinioError>()));
    });

    test('upload and download with a custom path', () async {
      var store =
          S3Store(s3Bucket, minio: minio, getObjectPath: newFilePathFunc());
      await store.upload('test_package', '2.0.0', testPackageData2);
      expect(await collectBytes(store.download('test_package', '2.0.0')),
          testPackageData2);
      await minio.statObject(
          s3Bucket, newFilePathFunc()('test_package', '2.0.0'));
    });

    test('checkHealth passes and leaves no probe behind', () async {
      await S3Store(s3Bucket, minio: minio).checkHealth();
      var listed = await minio.listAllObjects(s3Bucket, prefix: '.unpub/');
      expect(listed.objects, isEmpty);
    });

    test('checkHealth fails for a missing bucket', () async {
      expect(S3Store('dart-pub-missing', minio: minio).checkHealth(),
          throwsA(isA<StateError>()));
    });

    test('checkHealth fails for wrong credentials', () async {
      var bad = createMinio('wrong-access-key', 'wrong-secret-key');
      expect(S3Store(s3Bucket, minio: bad).checkHealth(), throwsA(anything));
    });
  }, skip: s3Endpoint == null ? 'UNPUB_TEST_S3_ENDPOINT is not set' : false);
}

/// A client for a bucket that exists, with optional write or delete failures.
class FakeMinio extends Minio {
  Object? putError;
  Object? removeError;
  final written = <String>[];
  final removed = <String>[];
  final copies = <List<String>>[];

  FakeMinio()
      : super(
            endPoint: 'localhost',
            accessKey: 'key',
            secretKey: 'secret',
            useSSL: false,
            region: 'us-east-1');

  @override
  Future<bool> bucketExists(String bucket) async => true;

  @override
  Future<String> putObject(
    String bucket,
    String object,
    Stream<Uint8List> data, {
    int? size,
    int? chunkSize,
    Map<String, String>? metadata,
    void Function(int)? onProgress,
  }) async {
    if (putError != null) throw putError!;
    written.add(object);
    return 'etag';
  }

  @override
  Future<s3.CopyObjectResult> copyObject(
    String bucket,
    String object,
    String srcObject, [
    s3.CopyConditions? conditions,
  ]) async {
    copies.add([object, srcObject]);
    return s3.CopyObjectResult('etag', DateTime.now());
  }

  @override
  Future<void> removeObject(String bucket, String object) async {
    if (removeError != null) throw removeError!;
    removed.add(object);
  }
}

class _HealthyMetaStore extends MetaStore {
  @override
  Future<void> addUploader(String name, String email) async {}

  @override
  Future<bool> addVersion(String name, UnpubVersion version) async => true;

  @override
  Future<void> replaceVersion(String name, UnpubVersion version) async {}

  @override
  Future<int> versionDownloads(String name, String version) async => 0;

  @override
  Future<bool> setVersionRetracted(
    String name,
    String version, {
    required bool retracted,
    DateTime? retractedAt,
    String? retractedBy,
  }) async =>
      true;

  @override
  Future<void> setDiscontinued(
    String name, {
    required bool discontinued,
    String? replacedBy,
    DateTime? discontinuedAt,
  }) async {}

  @override
  void increaseDownloads(String name, String version) {}

  @override
  Future<UnpubPackage?> queryPackage(String name) async => null;

  @override
  Future<UnpubQueryResult> queryPackages({
    required int size,
    required int page,
    required String sort,
    String? keyword,
    String? uploader,
    String? dependency,
    bool includeDiscontinued = true,
  }) async =>
      UnpubQueryResult(0, []);

  @override
  Future<void> removeUploader(String name, String email) async {}
}

Minio createMinio(String accessKey, String secretKey) {
  var endpoint = Uri.parse('http://$s3Endpoint');
  return Minio(
    endPoint: endpoint.host,
    port: endpoint.port,
    useSSL: false,
    region: 'us-east-1',
    accessKey: accessKey,
    secretKey: secretKey,
  );
}

const testPackageData = [
  0x8b, 0x1f, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x03, //
  0x02, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 //
];

// A tar.gz file with a `hello.txt` file that has `hello` written inside.
const testPackageData2 = [
  31, 139, 8, 0, 4, 81, 79, 97, 0, 3, 237, 207, 73, 10, 128, 48, 12, 5, //
  80, 215, 158, 34, 39, 144, 84, 99, 123, 30, 209, 138, 139, 98, 193, 214, //
  233, 246, 142, 116, 37, 238, 84, 132, 188, 205, 39, 16, 194, 79, 163, //
  141, 177, 137, 159, 124, 244, 28, 68, 148, 68, 176, 165, 82, 98, 79, 76, //
  143, 249, 36, 65, 144, 72, 51, 153, 99, 38, 17, 80, 144, 162, 60, 2, //
  124, 176, 83, 208, 59, 95, 116, 107, 149, 210, 26, 237, 188, 30, 116, //
  235, 108, 123, 177, 183, 174, 213, 245, 205, 157, 227, 17, 8, 249, 19, //
  141, 29, 171, 57, 254, 186, 5, 99, 140, 177, 183, 45, 78, 193, 149, 248, //
  0, 8, 0, 0,
];

String Function(String, String) newFilePathFunc() {
  return (String package, String version) {
    var grp = package[0];
    var subgrp = package.substring(0, 2);
    return path.join('packages', grp, subgrp, package, 'versions',
        '$package-$version.tar.gz');
  };
}
