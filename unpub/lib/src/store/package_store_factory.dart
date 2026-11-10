import '../config/config.dart';
import 'aws_credentials.dart';
import 'file_store.dart';
import 'package_store.dart';
import 's3_store.dart';

/// The package store described by [storage].
///
/// A [FileStore] does not create its directory here, so that read-only
/// commands leave the disk alone. The server calls `createBaseDir` itself.
Future<PackageStore> createPackageStore(StorageConfig storage) async {
  final s3 = storage.s3;
  if (s3 == null) return FileStore(storage.file.path);
  return S3Store(
    s3.bucket,
    region: s3.region,
    endpoint: s3.endpoint,
    port: s3.port,
    useSSL: s3.useSSL,
    pathStyle: s3.pathStyle,
    credentials: await AwsCredentials.resolve(
      accessKeyId: s3.accessKey,
      secretAccessKey: s3.secretKey,
      sessionToken: s3.sessionToken,
    ),
  );
}
