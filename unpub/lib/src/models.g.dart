// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'models.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

UnpubVersion _$UnpubVersionFromJson(Map<String, dynamic> json) => UnpubVersion(
      json['version'] as String,
      json['pubspec'] as Map<String, dynamic>,
      json['pubspecYaml'] as String?,
      json['uploader'] as String?,
      json['readme'] as String?,
      json['changelog'] as String?,
      identity(json['createdAt'] as DateTime),
    );

Map<String, dynamic> _$UnpubVersionToJson(UnpubVersion instance) =>
    <String, dynamic>{
      'version': instance.version,
      'pubspec': instance.pubspec,
      if (instance.pubspecYaml case final value?) 'pubspecYaml': value,
      if (instance.uploader case final value?) 'uploader': value,
      if (instance.readme case final value?) 'readme': value,
      if (instance.changelog case final value?) 'changelog': value,
      'createdAt': identity(instance.createdAt),
    };

UnpubPackage _$UnpubPackageFromJson(Map<String, dynamic> json) => UnpubPackage(
      json['name'] as String,
      (json['versions'] as List<dynamic>)
          .map((e) => UnpubVersion.fromJson(e as Map<String, dynamic>))
          .toList(),
      json['private'] as bool,
      (json['uploaders'] as List<dynamic>?)?.map((e) => e as String).toList(),
      identity(json['createdAt'] as DateTime),
      identity(json['updatedAt'] as DateTime),
      (json['download'] as num?)?.toInt(),
    );

Map<String, dynamic> _$UnpubPackageToJson(UnpubPackage instance) =>
    <String, dynamic>{
      'name': instance.name,
      'versions': instance.versions,
      'private': instance.private,
      'uploaders': instance.uploaders,
      'createdAt': identity(instance.createdAt),
      'updatedAt': identity(instance.updatedAt),
      'download': instance.download,
    };

UnpubQueryResult _$UnpubQueryResultFromJson(Map<String, dynamic> json) =>
    UnpubQueryResult(
      (json['count'] as num).toInt(),
      (json['packages'] as List<dynamic>)
          .map((e) => UnpubPackage.fromJson(e as Map<String, dynamic>))
          .toList(),
    );

Map<String, dynamic> _$UnpubQueryResultToJson(UnpubQueryResult instance) =>
    <String, dynamic>{
      'count': instance.count,
      'packages': instance.packages,
    };

DartRepoSeretModel _$DartRepoSeretModelFromJson(Map<String, dynamic> json) =>
    DartRepoSeretModel(
      tokens: (json['tokens'] as List<dynamic>?)
          ?.map((e) => Tokens.fromJson(e as Map<String, dynamic>))
          .toList(),
      uploadTokens: (json['uploadTokens'] as List<dynamic>?)
          ?.map((e) => Tokens.fromJson(e as Map<String, dynamic>))
          .toList(),
    );

Map<String, dynamic> _$DartRepoSeretModelToJson(DartRepoSeretModel instance) =>
    <String, dynamic>{
      'tokens': instance.tokens?.map((e) => e.toJson()).toList(),
      'uploadTokens': instance.uploadTokens?.map((e) => e.toJson()).toList(),
    };

Tokens _$TokensFromJson(Map<String, dynamic> json) => Tokens(
      name: json['name'] as String?,
      email: json['email'] as String?,
      token: json['token'] as String?,
    )..organization = json['organization'] as String?;

Map<String, dynamic> _$TokensToJson(Tokens instance) => <String, dynamic>{
      'name': instance.name,
      'email': instance.email,
      'organization': instance.organization,
      'token': instance.token,
    };
