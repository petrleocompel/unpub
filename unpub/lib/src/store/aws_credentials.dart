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

  /// Resolves credentials from, in order: the explicit arguments, the
  /// `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` variables, and the ECS
  /// container endpoint named by `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`.
  ///
  /// Throws [ArgumentError] when none of them yield credentials.
  static Future<AwsCredentials> resolve({
    String? accessKeyId,
    String? secretAccessKey,
    String? sessionToken,
    Map<String, String>? environment,
    http.Client? httpClient,
  }) async {
    final env = environment ?? Platform.environment;
    final key = accessKeyId ?? env['AWS_ACCESS_KEY_ID'];
    final secret = secretAccessKey ?? env['AWS_SECRET_ACCESS_KEY'];
    if (key != null && secret != null) {
      return AwsCredentials(
        accessKeyId: key,
        secretAccessKey: secret,
        sessionToken: sessionToken ?? env['AWS_SESSION_TOKEN'],
      );
    }

    final relativeUri = env['AWS_CONTAINER_CREDENTIALS_RELATIVE_URI'];
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
