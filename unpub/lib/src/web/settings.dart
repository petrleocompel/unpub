import '../config/config.dart';
import '../redact.dart';

const _redacted = '<redacted>';
const _unset = '(not set)';

String _secret(String? value) =>
    value == null || value.isEmpty ? _unset : _redacted;

String _list(List<String> values) =>
    values.isEmpty ? '(none)' : values.join(', ');

String _duration(Duration? duration) {
  if (duration == null) return '(none)';
  if (duration.inSeconds % 86400 == 0) return '${duration.inDays}d';
  if (duration.inSeconds % 3600 == 0) return '${duration.inHours}h';
  if (duration.inSeconds % 60 == 0) return '${duration.inMinutes}m';
  return '${duration.inSeconds}s';
}

/// The effective [config] by section, with every secret replaced.
///
/// Values are listed explicitly rather than reflected, so that a secret added
/// to the configuration later is not shown by accident.
Map<String, Map<String, String>> settingsOverview(Config config) {
  final s3 = config.storage.s3;
  final admin = config.auth.admin;
  return {
    'server': {
      'host': config.server.host,
      'port': '${config.server.port}',
      'publicUrl': config.server.publicUrl?.toString() ?? _unset,
      'trustForwardedFor': '${config.server.trustForwardedFor}',
    },
    'mongo': {'uri': redactUri(config.mongo.uri)},
    'storage': {
      'type': config.storage.type.name,
      if (config.storage.type == StorageType.file)
        'file.path': config.storage.file.path,
      if (s3 != null) ...{
        's3.bucket': s3.bucket,
        's3.region': s3.region,
        's3.endpoint': s3.endpoint,
        's3.port': s3.port?.toString() ?? _unset,
        's3.useSSL': '${s3.useSSL}',
        's3.pathStyle': s3.pathStyle?.toString() ?? '(automatic)',
        's3.accessKey': _secret(s3.accessKey),
        's3.secretKey': _secret(s3.secretKey),
        's3.sessionToken': _secret(s3.sessionToken),
      },
    },
    'upstream': {
      'url': redactUri(config.upstream.url.toString()),
      'mode': config.upstream.mode.name,
      'cacheTtl': _duration(config.upstream.cacheTtl),
      'allowlist': _list(config.upstream.allowlist),
      'timeout': _duration(config.upstream.timeout),
      'allowedArchiveHosts': _list(config.upstream.allowedArchiveHosts),
      'requireSha256': '${config.upstream.requireSha256}',
      'allowPublishWhenUnavailable':
          '${config.upstream.allowPublishWhenUnavailable}',
      'maxArchiveBytes': '${config.upstream.maxArchiveBytes}',
      'maxConcurrentFetches': '${config.upstream.maxConcurrentFetches}',
    },
    'publish': {
      'allowedNamePrefixes': _list(config.publish.allowedNamePrefixes),
      'maxArchiveBytes': '${config.publish.maxArchiveBytes}',
      'maxUnpackedBytes': '${config.publish.maxUnpackedBytes}',
      'requiredFiles': _list(config.publish.requiredFiles),
      'rejectOlderThanLatest': '${config.publish.rejectOlderThanLatest}',
      'requireVersionBump': '${config.publish.requireVersionBump}',
      'retractionWindow': _duration(config.publish.retractionWindow),
      'uploadTimeout': _duration(config.publish.uploadTimeout),
    },
    'auth': {
      'readAccess': config.auth.readAccess.name,
      'bootstrapToken': _secret(config.auth.bootstrapToken),
      'bootstrapEmail': config.auth.bootstrapEmail,
      'readTokens': config.auth.readTokens.isEmpty
          ? '(none)'
          : '${config.auth.readTokens.length} configured, $_redacted',
      'admin.email': admin?.email ?? _unset,
      'admin.password': _secret(admin?.password),
    },
    'audit': {
      'retentionDays': config.audit.retentionDays == 0
          ? '0 (kept forever)'
          : '${config.audit.retentionDays}',
    },
    'webhooks': {
      'enabled': '${config.webhooks.enabled}',
      'timeout': _duration(config.webhooks.timeout),
      'maxAttempts': '${config.webhooks.maxAttempts}',
      'allowHttp': '${config.webhooks.allowHttp}',
      'allowPrivateNetworks': '${config.webhooks.allowPrivateNetworks}',
      'retentionDays': config.webhooks.retentionDays == 0
          ? '0 (kept forever)'
          : '${config.webhooks.retentionDays}',
    },
    'logging': {
      'level': config.logging.level.name,
      'format': config.logging.format.name,
    },
  };
}
