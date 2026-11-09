import 'package:json_annotation/json_annotation.dart';

part 'webapi_models.g.dart';

@JsonSerializable()
class ListApi {
  int count;
  List<ListApiPackage> packages;

  ListApi(this.count, this.packages);

  factory ListApi.fromJson(Map<String, dynamic> map) => _$ListApiFromJson(map);
  Map<String, dynamic> toJson() => _$ListApiToJson(this);
}

@JsonSerializable()
class ListApiPackage {
  String name;
  String? description;
  List<String> tags;
  String latest;
  DateTime updatedAt;
  bool isDiscontinued;
  String? replacedBy;
  int downloads;

  ListApiPackage(
      this.name, this.description, this.tags, this.latest, this.updatedAt,
      {this.isDiscontinued = false, this.replacedBy, this.downloads = 0});

  factory ListApiPackage.fromJson(Map<String, dynamic> map) =>
      _$ListApiPackageFromJson(map);
  Map<String, dynamic> toJson() => _$ListApiPackageToJson(this);
}

@JsonSerializable()
class DetailViewVersion {
  String version;
  DateTime createdAt;
  bool isRetracted;
  int downloads;
  String? uploader;

  DetailViewVersion(this.version, this.createdAt,
      {this.isRetracted = false, this.downloads = 0, this.uploader});

  factory DetailViewVersion.fromJson(Map<String, dynamic> map) =>
      _$DetailViewVersionFromJson(map);

  Map<String, dynamic> toJson() => _$DetailViewVersionToJson(this);
}

@JsonSerializable()
class WebapiDetailView {
  String name;
  String version;
  String description;
  String homepage;
  List<String> uploaders;
  DateTime createdAt;
  final String? readme;
  final String? changelog;
  List<DetailViewVersion> versions;
  List<String?> authors;
  List<String>? dependencies;
  List<String> tags;
  bool isRetracted;
  DateTime? retractedAt;
  bool isDiscontinued;
  String? replacedBy;
  DateTime? discontinuedAt;

  /// Download counts, keyed `version` and `package`.
  Map<String, int> downloads;

  WebapiDetailView(
      this.name,
      this.version,
      this.description,
      this.homepage,
      this.uploaders,
      this.createdAt,
      this.readme,
      this.changelog,
      this.versions,
      this.authors,
      this.dependencies,
      this.tags,
      {this.isRetracted = false,
      this.retractedAt,
      this.isDiscontinued = false,
      this.replacedBy,
      this.discontinuedAt,
      this.downloads = const {}});

  factory WebapiDetailView.fromJson(Map<String, dynamic> map) =>
      _$WebapiDetailViewFromJson(map);

  Map<String, dynamic> toJson() => _$WebapiDetailViewToJson(this);
}
