import 'package:json_annotation/json_annotation.dart';
import 'package:pub_semver/pub_semver.dart' as semver;

part 'models.g.dart';

DateTime identity(DateTime x) => x;

DateTime? optionalIdentity(DateTime? x) => x;

@JsonSerializable()
class UnpubVersion {
  final String version;
  final Map<String, dynamic> pubspec;
  final String? pubspecYaml;
  final String? uploader; // TODO: not sure why null. keep it nullable
  final String? readme;
  final String? changelog;

  @JsonKey(fromJson: identity, toJson: identity)
  final DateTime createdAt;

  /// Lowercase hex SHA-256 of the stored archive. Null for a version published
  /// before hashes were recorded and not yet backfilled by `unpub migrate`.
  final String? sha256;

  @JsonKey(defaultValue: false)
  final bool isRetracted;

  @JsonKey(fromJson: optionalIdentity, toJson: optionalIdentity)
  final DateTime? retractedAt;

  /// Email of whoever retracted this version.
  final String? retractedBy;

  UnpubVersion(
    this.version,
    this.pubspec,
    this.pubspecYaml,
    this.uploader,
    this.readme,
    this.changelog,
    this.createdAt, {
    this.sha256,
    this.isRetracted = false,
    this.retractedAt,
    this.retractedBy,
  });

  factory UnpubVersion.fromJson(Map<String, dynamic> map) =>
      _$UnpubVersionFromJson(map);

  /// Omits unset fields, so that stored documents keep their existing shape.
  Map<String, dynamic> toJson() => _$UnpubVersionToJson(this)
    ..removeWhere((key, value) =>
        value == null || (key == 'isRetracted' && value == false));
}

@JsonSerializable(createToJson: false)
class UnpubPackage {
  final String name;
  final List<UnpubVersion> versions;
  final bool private;
  final List<String>? uploaders;

  @JsonKey(fromJson: identity, toJson: identity)
  final DateTime createdAt;

  @JsonKey(fromJson: identity, toJson: identity)
  final DateTime updatedAt;

  final int? download;

  @JsonKey(defaultValue: false)
  final bool isDiscontinued;

  /// The package to use instead, when this one is discontinued.
  final String? replacedBy;

  @JsonKey(fromJson: optionalIdentity)
  final DateTime? discontinuedAt;

  UnpubPackage(
    this.name,
    this.versions,
    this.private,
    this.uploaders,
    this.createdAt,
    this.updatedAt,
    this.download, {
    this.isDiscontinued = false,
    this.replacedBy,
    this.discontinuedAt,
  });

  factory UnpubPackage.fromJson(Map<String, dynamic> map) =>
      _$UnpubPackageFromJson(map);

  /// The version a client gets by default.
  ///
  /// The highest version that is neither a prerelease nor retracted, then the
  /// highest prerelease that is not retracted. If every version is retracted,
  /// the highest one anyway.
  UnpubVersion get latest {
    final available = versions.where((v) => !v.isRetracted).toList();
    if (available.isEmpty) return _highest(versions);
    final stable =
        available.where((v) => !_parse(v.version).isPreRelease).toList();
    return _highest(stable.isEmpty ? available : stable);
  }

  /// The highest version that is not retracted, prereleases included, or null
  /// if every version is retracted.
  UnpubVersion? get highestAvailable {
    final available = versions.where((v) => !v.isRetracted).toList();
    return available.isEmpty ? null : _highest(available);
  }

  static UnpubVersion _highest(List<UnpubVersion> versions) =>
      versions.reduce((a, b) => _parse(a.version) >= _parse(b.version) ? a : b);

  /// Treats a stored version that does not parse as the lowest, so that one
  /// bad document cannot break the whole package list.
  static semver.Version _parse(String version) {
    try {
      return semver.Version.parse(version);
    } on FormatException {
      return semver.Version.none;
    }
  }
}

@JsonSerializable(createToJson: false)
class UnpubQueryResult {
  int count;
  List<UnpubPackage> packages;

  UnpubQueryResult(this.count, this.packages);

  factory UnpubQueryResult.fromJson(Map<String, dynamic> map) =>
      _$UnpubQueryResultFromJson(map);
}
