import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:minio/minio.dart';

import '../logging.dart';
import 'aws_credentials.dart';
import 'package_store.dart';

final _log = Logger('unpub.s3');

/// Use an AWS S3 bucket, or an S3 compatible service, as a package store.
class S3Store extends PackageStore {
  final String bucketName;
  final String Function(String name, String version)? getObjectPath;
  final String? region;
  final Minio _minio;

  S3Store._(this.bucketName, this.region, this.getObjectPath, this._minio);

  /// Creates a store for [bucketName].
  ///
  /// Either pass a preconfigured [minio] client, or [credentials] to have one
  /// created. The region comes from [region] or `AWS_DEFAULT_REGION`, and the
  /// endpoint from [endpoint], `AWS_S3_ENDPOINT` or `s3.amazonaws.com`.
  factory S3Store(
    String bucketName, {
    String? region,
    String? endpoint,
    int? port,
    bool useSSL = true,
    bool? pathStyle,
    AwsCredentials? credentials,
    Minio? minio,
    String Function(String name, String version)? getObjectPath,
    Map<String, String>? environment,
  }) {
    final env = environment ?? Platform.environment;
    final resolvedRegion =
        region ?? minio?.region ?? _nonEmpty(env['AWS_DEFAULT_REGION']);
    if (resolvedRegion == null) {
      throw ArgumentError('Could not determine a default region for aws.');
    }
    if (minio == null && credentials == null) {
      throw ArgumentError(
          'S3Store needs either credentials or a Minio client.');
    }
    return S3Store._(
      bucketName,
      resolvedRegion,
      getObjectPath,
      minio ??
          Minio(
            endPoint: endpoint ?? env['AWS_S3_ENDPOINT'] ?? 's3.amazonaws.com',
            port: port,
            useSSL: useSSL,
            pathStyle: pathStyle,
            region: resolvedRegion,
            accessKey: credentials!.accessKeyId,
            secretKey: credentials.secretAccessKey,
            sessionToken: credentials.sessionToken,
          ),
    );
  }

  static String? _nonEmpty(String? value) =>
      value == null || value.isEmpty ? null : value;

  /// Characters that could change which object a name or version refers to.
  static final _unsafeComponent = RegExp(r'[/\\\x00-\x1f\x7f]|\.\.');

  /// The same check for a whole key, in which `/` is the expected separator.
  static final _unsafeKey = RegExp(r'[\\\x00-\x1f\x7f]|\.\.');

  /// The object key of [name] [version].
  ///
  /// Throws an [ArgumentError] for values that could address another object.
  String _getObjectKey(String name, String version) {
    _checkComponents(name, version);
    final key =
        getObjectPath?.call(name, version) ?? '$name/$name-$version.tar.gz';
    if (key.startsWith('/') || _unsafeKey.hasMatch(key)) {
      throw ArgumentError('unsafe object key');
    }
    return key;
  }

  /// The object key of a proxied archive, named by the digest of its bytes.
  /// It has three path segments, while the default key of a locally published
  /// archive has two.
  String _getUpstreamKey(String name, String version, String digest) {
    _checkComponents(name, version);
    PackageStore.checkDigest(digest);
    return 'upstream/$name/$name-$version-$digest.tar.gz';
  }

  /// Where an archive waits until its metadata is written. It has three path
  /// segments, so it is never the default key of a published archive, and a
  /// package called `staging` does not reach it.
  String _getStagingKey(String name, String version, String id) {
    _checkComponents(name, version);
    PackageStore.checkStagingId(id);
    return 'staging/$name/$name-$version-$id.tar.gz';
  }

  static void _checkComponents(String name, String version) {
    if (_unsafeComponent.hasMatch(name) || _unsafeComponent.hasMatch(version)) {
      throw ArgumentError('unsafe package name or version');
    }
  }

  @override
  Future<void> upload(String name, String version, List<int> content) async {
    await _minio.putObject(
      bucketName,
      _getObjectKey(name, version),
      Stream.value(Uint8List.fromList(content)),
      size: content.length,
    );
  }

  @override
  Future<void> stageArchive(
      String name, String version, String id, List<int> content) async {
    await _minio.putObject(
      bucketName,
      _getStagingKey(name, version, id),
      Stream.value(Uint8List.fromList(content)),
      size: content.length,
    );
  }

  /// A failure to delete the staged object only leaves it for reclamation.
  @override
  Future<void> commitStaged(String name, String version, String id,
      {bool replace = false}) async {
    final target = _getObjectKey(name, version);
    final staged = _getStagingKey(name, version, id);
    if (!replace && await _objectExists(target)) {
      throw ArchiveExistsException(name, version);
    }
    // The copy source goes into a header as it is, where a `+` in a version
    // would be read as a space.
    final source = staged.split('/').map(Uri.encodeComponent).join('/');
    await _minio.copyObject(bucketName, target, '/$bucketName/$source');
    try {
      await _minio.removeObject(bucketName, staged);
    } catch (error, stackTrace) {
      _log.warning(
          LogEvent('failed to delete a staged archive',
              {'name': name, 'version': version}),
          error,
          stackTrace);
    }
  }

  @override
  Future<void> discardStaged(String name, String version, String id) async {
    await _minio.removeObject(bucketName, _getStagingKey(name, version, id));
  }

  @override
  Future<bool> hasCommittedArchive(String name, String version) =>
      exists(name, version);

  @override
  Future<bool> exists(String name, String version) =>
      _objectExists(_getObjectKey(name, version));

  Future<bool> _objectExists(String key) async {
    try {
      await _minio.statObject(bucketName, key, retrieveAcls: false);
      return true;
    } on MinioS3Error catch (error) {
      if (error.response?.statusCode == HttpStatus.notFound) return false;
      rethrow;
    }
  }

  @override
  Stream<List<int>> download(String name, String version) async* {
    yield* await _minio.getObject(bucketName, _getObjectKey(name, version));
  }

  /// Streams the file, so that its size does not matter. Storing the same
  /// digest twice stores the same bytes. [temporary] stays where it is, for
  /// the caller to delete.
  @override
  Future<bool> commitUpstream(String name, String version, String digest,
      File temporary, int size) async {
    await _minio.putObject(
      bucketName,
      _getUpstreamKey(name, version, digest),
      temporary.openRead().map(_asBytes),
      size: size,
    );
    return true;
  }

  static Uint8List _asBytes(List<int> chunk) =>
      chunk is Uint8List ? chunk : Uint8List.fromList(chunk);

  @override
  Future<bool> upstreamCached(
          String name, String version, String digest) async =>
      _objectExists(_getUpstreamKey(name, version, digest));

  @override
  Stream<List<int>> downloadUpstream(
      String name, String version, String digest) async* {
    yield* await _minio.getObject(
        bucketName, _getUpstreamKey(name, version, digest));
  }

  @override
  Future<void> deleteUpstream(String name, String version, String digest) =>
      _minio.removeObject(bucketName, _getUpstreamKey(name, version, digest));

  /// `staging/<name>/<name>-<version>-<id>.tar.gz`, and nothing else.
  static final _stagingKeyPattern =
      RegExp(r'^staging/([^/]+)/\1-.+-[0-9A-Za-z]+\.tar\.gz$');

  /// Also clears the local spool files that the upstream proxy writes to,
  /// since those are the temporary files of this store too.
  @override
  Future<int> reclaimTemporary(
      {DateTime? now, Duration maxAge = temporaryFileMaxAge}) async {
    var count = await super.reclaimTemporary(now: now, maxAge: maxAge);
    final cutoff = (now ?? DateTime.now()).subtract(maxAge);
    final listed = await _minio.listAllObjects(bucketName,
        prefix: 'staging/', recursive: true);
    for (final object in listed.objects) {
      final key = object.key;
      final modified = object.lastModified;
      if (key == null ||
          modified == null ||
          !_stagingKeyPattern.hasMatch(key) ||
          !modified.isBefore(cutoff)) {
        continue;
      }
      await _minio.removeObject(bucketName, key);
      count++;
    }
    return count;
  }

  /// Verifies the bucket exists and accepts writes and deletes, by storing and
  /// removing a probe object.
  ///
  /// The probe lives under `.unpub/`, a prefix no package name can start with.
  @override
  Future<void> checkHealth() async {
    if (!await _minio.bucketExists(bucketName)) {
      throw StateError('bucket "$bucketName" does not exist');
    }
    final content = Uint8List.fromList(utf8.encode('ok'));
    final key = '.unpub/readyz-${_randomId()}';
    try {
      await _minio.putObject(bucketName, key, Stream.value(content),
          size: content.length);
    } catch (error) {
      throw StateError('cannot write to bucket "$bucketName": $error');
    }
    try {
      await _minio.removeObject(bucketName, key);
    } catch (error) {
      throw StateError('cannot delete from bucket "$bucketName": $error');
    }
  }

  static String _randomId() {
    final random = Random.secure();
    return List.generate(
            16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
  }
}
