import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Credentials for AWS S3 or an S3 compatible service.
class AwsCredentials {
  final String accessKeyId;
  final String secretAccessKey;
  final String? sessionToken;

  const AwsCredentials({
    required this.accessKeyId,
    required this.secretAccessKey,
    this.sessionToken,
  });

  /// Resolves credentials from the first complete source of: the explicit
  /// arguments, the `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` variables
  /// with `AWS_SESSION_TOKEN`, and the ECS container endpoint named by
  /// `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`.
  ///
  /// Values are never combined across sources, because a session token only
  /// works with the keys it was issued for.
  ///
  /// Throws [ArgumentError] when explicit arguments are incomplete, or when
  /// no source yields credentials.
  static Future<AwsCredentials> resolve({
    String? accessKeyId,
    String? secretAccessKey,
    String? sessionToken,
    Map<String, String>? environment,
    http.Client? httpClient,
  }) async {
    if (accessKeyId != null && secretAccessKey != null) {
      return AwsCredentials(
        accessKeyId: accessKeyId,
        secretAccessKey: secretAccessKey,
        sessionToken: sessionToken,
      );
    }
    if (accessKeyId != null ||
        secretAccessKey != null ||
        sessionToken != null) {
      throw ArgumentError(
          'An explicit session token, access key or secret key needs both the '
          'access key and the secret key.');
    }

    final env = environment ?? Platform.environment;
    String? variable(String name) {
      final value = env[name];
      return value == null || value.isEmpty ? null : value;
    }

    final key = variable('AWS_ACCESS_KEY_ID');
    final secret = variable('AWS_SECRET_ACCESS_KEY');
    if (key != null && secret != null) {
      return AwsCredentials(
        accessKeyId: key,
        secretAccessKey: secret,
        sessionToken: variable('AWS_SESSION_TOKEN'),
      );
    }

    final relativeUri = variable('AWS_CONTAINER_CREDENTIALS_RELATIVE_URI');
    if (relativeUri != null) {
      return _fromContainer(relativeUri, httpClient);
    }

    throw ArgumentError(
        'You must provide a valid Access Key and Secret for AWS.');
  }

  static Future<AwsCredentials> _fromContainer(
      String relativeUri, http.Client? httpClient) async {
    final client = httpClient ?? http.Client();
    try {
      final url = Uri.parse('http://169.254.170.2$relativeUri');
      final data = json.decode(await client.read(url)) as Map<String, dynamic>;
      return AwsCredentials(
        accessKeyId: data['AccessKeyId'] as String,
        secretAccessKey: data['SecretAccessKey'] as String,
        sessionToken: data['Token'] as String?,
      );
    } finally {
      if (httpClient == null) client.close();
    }
  }
}
