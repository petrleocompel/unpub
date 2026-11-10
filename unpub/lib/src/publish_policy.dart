import 'dart:io';
import 'dart:typed_data';

import 'package:pub_semver/pub_semver.dart';

import 'config/config.dart';
import 'models.dart';

/// An upload that a `publish` setting refuses. [toString] is what
/// `dart pub publish` prints, and names the setting.
class PublishPolicyViolation implements Exception {
  final String message;

  const PublishPolicyViolation(this.message);

  @override
  String toString() => message;
}

class _LimitedBytesSink implements Sink<List<int>> {
  final int limit;
  final _bytes = BytesBuilder(copy: false);

  _LimitedBytesSink(this.limit);

  @override
  void add(List<int> chunk) {
    if (_bytes.length + chunk.length > limit) {
      throw PublishPolicyViolation('publish.maxUnpackedBytes: the archive '
          'unpacks to more than the limit of $limit bytes.');
    }
    _bytes.add(chunk);
  }

  @override
  void close() {}

  Uint8List takeBytes() => _bytes.takeBytes();
}

/// Applies the `publish` settings to an upload.
class PublishPolicy {
  final PublishConfig config;

  const PublishPolicy(this.config);

  int get maxArchiveBytes => config.maxArchiveBytes;

  /// Refuses an archive of [size] bytes when that is over the limit.
  void checkSize(int size) {
    if (size > config.maxArchiveBytes) throw archiveTooLarge(size);
  }

  /// The refusal of an archive of [size] bytes, or of unknown size when the
  /// body was not read.
  PublishPolicyViolation archiveTooLarge([int? size]) =>
      PublishPolicyViolation('publish.maxArchiveBytes: the archive'
          '${size == null ? '' : ' is $size bytes, which'} exceeds the limit '
          'of ${config.maxArchiveBytes} bytes.');

  /// [gzipped] inflated, refused as soon as it passes `maxUnpackedBytes`.
  ///
  /// The decoder hands over each block as it inflates, so a compression bomb
  /// is stopped at the limit instead of filling the memory first.
  Uint8List inflate(List<int> gzipped) {
    final output = _LimitedBytesSink(config.maxUnpackedBytes);
    final decoder = gzip.decoder.startChunkedConversion(output);
    decoder.add(gzipped);
    decoder.close();
    return output.takeBytes();
  }

  /// Refuses [name] unless it starts with an allowed prefix.
  void checkName(String name) {
    final prefixes = config.allowedNamePrefixes;
    if (prefixes.isEmpty || prefixes.any(name.startsWith)) return;
    throw PublishPolicyViolation('publish.allowedNamePrefixes: $name must '
        'start with one of: ${prefixes.join(', ')}.');
  }

  /// Refuses an archive without the required files, where [archivePaths] are
  /// the paths of the files it holds.
  void checkRequiredFiles(Iterable<String> archivePaths) {
    if (config.requiredFiles.isEmpty) return;
    final present = {
      for (final path in archivePaths)
        if (!_withoutDotPrefix(path).contains('/'))
          _withoutDotPrefix(path).toLowerCase(),
    };
    final missing = [
      for (final file in config.requiredFiles)
        if (!present.contains(file.toLowerCase())) file,
    ];
    if (missing.isEmpty) return;
    throw PublishPolicyViolation('publish.requiredFiles: the archive must '
        'contain ${missing.join(', ')} at its root.');
  }

  static String _withoutDotPrefix(String path) =>
      path.startsWith('./') ? path.substring(2) : path;

  /// Refuses publishing [version] given the versions [package] already has.
  void checkVersion(UnpubPackage package, String version) {
    if (config.requireVersionBump &&
        package.versions.any((item) => item.version == version)) {
      throw duplicateVersion(package.name, version);
    }
    if (!config.rejectOlderThanLatest) return;
    final highest = package.highestAvailable;
    if (highest != null &&
        Version.parse(version) < Version.parse(highest.version)) {
      throw PublishPolicyViolation('publish.rejectOlderThanLatest: $version '
          'is lower than the highest version ${highest.version}.');
    }
  }

  /// The refusal of a version that [name] already has.
  static PublishPolicyViolation duplicateVersion(String name, String version) =>
      PublishPolicyViolation('version invalid: $name@$version already exists. '
          '(publish.requireVersionBump)');

  /// The refusal of a version that a concurrent request is publishing.
  static PublishPolicyViolation concurrentPublish(
          String name, String version) =>
      PublishPolicyViolation(
          'version is being published by another request: $name@$version');

  /// Whether the retraction window has closed for a version published at
  /// [publishedAt].
  bool retractionWindowClosed(DateTime publishedAt, DateTime now) {
    final window = config.retractionWindow;
    return window != null && now.difference(publishedAt) > window;
  }
}
