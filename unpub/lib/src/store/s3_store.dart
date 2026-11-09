import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:minio/minio.dart';

import 'aws_credentials.dart';
import 'package_store.dart';

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
    if (_unsafeComponent.hasMatch(name) || _unsafeComponent.hasMatch(version)) {
      throw ArgumentError('unsafe package name or version');
    }
    final key =
        getObjectPath?.call(name, version) ?? '$name/$name-$version.tar.gz';
    if (key.startsWith('/') || _unsafeKey.hasMatch(key)) {
      throw ArgumentError('unsafe object key');
    }
    return key;
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
  Future<bool> exists(String name, String version) async {
    try {
      await _minio.statObject(bucketName, _getObjectKey(name, version),
          retrieveAcls: false);
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
