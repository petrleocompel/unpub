/// One version of a package in the format of the pub API.
Map<String, dynamic> pubVersionJson({
  required String archiveUrl,
  required Object? pubspec,
  required String version,
  String? archiveSha256,
  Object? published,
  bool retracted = false,
}) =>
    {
      'archive_url': archiveUrl,
      if (archiveSha256 != null) 'archive_sha256': archiveSha256,
      'pubspec': pubspec,
      'version': version,
      if (published != null) 'published': published,
      if (retracted) 'retracted': true,
    };

/// A package listing in the format of the pub API.
Map<String, dynamic> pubPackageJson({
  required String name,
  required Map<String, dynamic>? latest,
  required List<Map<String, dynamic>> versions,
  required bool isDiscontinued,
  Object? replacedBy,
  Object? advisoriesUpdated,
}) =>
    {
      'name': name,
      if (latest != null) 'latest': latest,
      'versions': versions,
      'isDiscontinued': isDiscontinued,
      if (replacedBy != null) 'replacedBy': replacedBy,
      if (advisoriesUpdated != null) 'advisoriesUpdated': advisoriesUpdated,
    };
