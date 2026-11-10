import 'dart:io';

import 'package:collection/collection.dart' show IterableExtension;
import 'package:pub_semver/pub_semver.dart' as semver;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart';

import '../app.dart';
import '../models.dart';
import '../utils.dart';
import '../validation.dart';
import '../webapi_models.dart';
import 'responses.dart';

/// The JSON endpoints of the former web UI, kept for scripts using them.
class WebapiRoutes {
  final App app;

  WebapiRoutes(this.app);

  void addRoutes(Router router) {
    router
      ..get('/webapi/packages', getPackages)
      ..get('/packages/<name>.json', getPackageVersions)
      ..get('/webapi/package/<name>/<version>', getPackageDetail);
  }

  Future<shelf.Response> getPackages(shelf.Request req) async {
    var params = req.requestedUri.queryParameters;
    var size = int.tryParse(params['size'] ?? '') ?? 10;
    var page = int.tryParse(params['page'] ?? '') ?? 0;
    var sort = params['sort'] ?? 'download';
    var q = params['q'];

    String? keyword;
    String? uploader;
    String? dependency;

    if (q == null) {
    } else if (q.startsWith('email:')) {
      uploader = q.substring(6).trim();
    } else if (q.startsWith('dependency:')) {
      dependency = q.substring(11).trim();
    } else {
      keyword = q;
    }

    final result = await app.metaStore.queryPackages(
      size: size,
      page: page,
      sort: sort,
      keyword: keyword,
      uploader: uploader,
      dependency: dependency,
      includeDiscontinued: params['discontinued'] == 'true',
    );

    var data = ListApi(result.count, [
      for (var package in result.packages)
        ListApiPackage(
          package.name,
          package.latest.pubspec['description'] as String?,
          getPackageTags(package.latest.pubspec),
          package.latest.version,
          package.updatedAt,
          isDiscontinued: package.isDiscontinued,
          replacedBy: package.replacedBy,
          downloads: package.download ?? 0,
        )
    ]);

    return okWithJson({'data': data.toJson()});
  }

  Future<shelf.Response> getPackageVersions(
      shelf.Request req, String name) async {
    if (!isValidPackageName(name)) return notFound();

    var package = await app.metaStore.queryPackage(name);
    if (package == null) {
      return badRequest('package not exists', status: HttpStatus.notFound);
    }

    var versions = package.versions.map((v) => v.version).toList();
    versions.sort((a, b) {
      return semver.Version.prioritize(
          semver.Version.parse(b), semver.Version.parse(a));
    });

    return okWithJson({
      'name': name,
      'versions': versions,
    });
  }

  Future<shelf.Response> getPackageDetail(
      shelf.Request req, String name, String version) async {
    if (!isValidPackageName(name)) return notFound();
    if (version != 'latest') {
      var decodedVersion = parseVersionSegment(version);
      if (decodedVersion == null) return notFound();
      version = decodedVersion;
    }

    var package = await app.metaStore.queryPackage(name);
    if (package == null) {
      return okWithJson({'error': 'package not exists'});
    }

    UnpubVersion? packageVersion;
    if (version == 'latest') {
      packageVersion = package.latest;
    } else {
      packageVersion =
          package.versions.firstWhereOrNull((item) => item.version == version);
    }
    if (packageVersion == null) {
      return okWithJson({'error': 'version not exists'});
    }

    final downloadCounts = await app.metaStore
        .versionDownloadCounts(name, package.versions.map((v) => v.version));
    var versions = package.versions
        .map((v) => DetailViewVersion(v.version, v.createdAt,
            isRetracted: v.isRetracted,
            downloads: downloadCounts[v.version] ?? 0,
            uploader: v.uploader))
        .toList();
    versions.sort((a, b) {
      return semver.Version.prioritize(
          semver.Version.parse(b.version), semver.Version.parse(a.version));
    });

    var pubspec = packageVersion.pubspec;
    List<String?> authors;
    if (pubspec['author'] != null) {
      authors = RegExp(r'<(.*?)>')
          .allMatches(pubspec['author'])
          .map((match) => match.group(1))
          .toList();
    } else if (pubspec['authors'] != null) {
      authors = (pubspec['authors'] as List)
          .map((author) => RegExp(r'<(.*?)>').firstMatch(author)!.group(1))
          .toList();
    } else {
      authors = [];
    }

    var depMap = (pubspec['dependencies'] as Map? ?? {}).cast<String, String>();

    var data = WebapiDetailView(
      package.name,
      packageVersion.version,
      packageVersion.pubspec['description'] ?? '',
      packageVersion.pubspec['homepage'] ?? '',
      package.uploaders ?? [],
      packageVersion.createdAt,
      packageVersion.readme,
      packageVersion.changelog,
      versions,
      authors,
      depMap.keys.toList(),
      getPackageTags(packageVersion.pubspec),
      isRetracted: packageVersion.isRetracted,
      retractedAt: packageVersion.retractedAt,
      isDiscontinued: package.isDiscontinued,
      replacedBy: package.replacedBy,
      discontinuedAt: package.discontinuedAt,
      downloads: {
        'version': downloadCounts[packageVersion.version] ?? 0,
        'package': package.download ?? 0,
      },
    );

    return okWithJson({'data': data.toJson()});
  }
}
