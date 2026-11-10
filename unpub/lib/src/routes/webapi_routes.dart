import 'dart:io';

import 'package:collection/collection.dart' show IterableExtension;
import 'package:pub_semver/pub_semver.dart' as semver;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart';

import '../app.dart';
import '../models.dart';
import '../redact.dart';
import '../utils.dart';
import '../validation.dart';
import '../version.dart';
import '../webapi_models.dart';
import '../web/download_stats.dart';
import '../web/markdown.dart';
import '../web/pages/package_list_page.dart' show PackageListRequest;
import '../web/pages/package_page.dart' show markdownLinks;
import '../web/pubspec_info.dart';
import 'responses.dart';

/// The package endpoints under `/webapi` and `GET /webapi/config`: those
/// of the web client, and those of the former web UI, kept for scripts.
class WebapiRoutes {
  final App app;

  WebapiRoutes(this.app);

  void addRoutes(Router router) {
    router
      ..get('/webapi/config', getConfig)
      ..get('/webapi/packages', getPackages)
      ..get('/webapi/v2/packages', listPackages)
      ..get('/packages/<name>.json', getPackageVersions)
      ..get('/webapi/package/<name>', getLatestPackage)
      // Before the version route, which `stats` would match.
      ..get('/webapi/package/<name>/stats', getPackageStats)
      ..get('/webapi/package/<name>/<version>', getPackageDetail);
  }

  static const _noStore = {HttpHeaders.cacheControlHeader: 'no-store'};

  /// What the web client needs to know before anything else. Open in every
  /// read mode, and without secrets.
  Future<shelf.Response> getConfig(shelf.Request req) async {
    final config = app.config;
    return okWithJson({
      'version': packageVersion,
      'publicUrl': app.publicUrl?.toString(),
      'readAccess': app.readAccess.name,
      'accounts': app.accountApi != null,
      'upstream': {
        'url': redactUri(app.upstream),
        'mode': app.upstreamProxy == null ? 'redirect' : 'proxy',
      },
      'features': {
        'metrics': config?.metrics.enabled ?? true,
        'webhooks': app.webhooks != null,
        'spa': app.spaClient != null,
        'classic': true,
      },
      'ui': {
        'mode': app.ui.mode.name,
        'basePath': app.ui.spaBasePath,
        'classicPath': app.ui.classicBasePath,
      },
    }, headers: _noStore);
  }

  /// The package list of the web client, with the search, filters, sorting
  /// and pages of the package list page.
  Future<shelf.Response> listPackages(shelf.Request req) async {
    final params = req.url.queryParameters;
    final request = PackageListRequest.fromQuery({
      ...params,
      'discontinued': params['discontinued'] == 'true' ? '1' : '0',
    });
    final result = await app.metaStore.searchPackages(request.search);
    return okWithJson({
      'items': [for (final package in result.packages) _summary(package)],
      'page': request.page,
      'size': request.size,
      'total': result.count,
    });
  }

  static Map<String, Object?> _summary(UnpubPackage package) {
    final latest = package.latest;
    return {
      'name': package.name,
      'latest': latest.version,
      'description': PubspecInfo(latest.pubspec).description,
      'updatedAt': package.updatedAt.toUtc().toIso8601String(),
      'downloads': package.download ?? 0,
      'isDiscontinued': package.isDiscontinued,
      'replacedBy': package.replacedBy,
      'isFlutter':
          package.versions.any((version) => isFlutterPubspec(version.pubspec)),
      'private': package.private,
    };
  }

  Future<shelf.Response> getLatestPackage(shelf.Request req, String name) =>
      getPackageDetail(req, name, 'latest');

  /// The downloads of a package as its statistics page shows them, with
  /// every version.
  Future<shelf.Response> getPackageStats(shelf.Request req, String name) async {
    if (!isValidPackageName(name)) return notFound();
    final package = await app.metaStore.queryPackage(name);
    if (package == null) return notFound('package not found');
    final stats = await DownloadStats.load(app.metaStore, name,
        total: package.download ?? 0,
        versions: package.versions.map((v) => v.version),
        top: null);
    final ranked = {
      for (final (version, count) in stats.topVersions) version: count
    };
    final versions = [
      ...stats.topVersions,
      for (final version in _sortedVersions(package))
        if (!ranked.containsKey(version.version)) (version.version, 0),
    ];
    return okWithJson({
      'name': name,
      'total': stats.total,
      'recent': stats.recent,
      'days': [
        for (final (day, count) in stats.days)
          {'day': isoDay(day), 'count': count},
      ],
      'versions': [
        for (final (version, downloads) in versions)
          {'version': version, 'downloads': downloads},
      ],
    });
  }

  /// The versions of [package], highest first.
  static List<UnpubVersion> _sortedVersions(UnpubPackage package) => [
        ...package.versions
      ]..sort((a, b) => _parse(b.version).compareTo(_parse(a.version)));

  static semver.Version _parse(String version) {
    try {
      return semver.Version.parse(version);
    } on FormatException {
      return semver.Version.none;
    }
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
    if (package == null) return notFound('package not found');

    UnpubVersion? packageVersion;
    if (version == 'latest') {
      packageVersion = package.latest;
    } else {
      packageVersion =
          package.versions.firstWhereOrNull((item) => item.version == version);
    }
    if (packageVersion == null) return notFound('version not found');

    final sorted = _sortedVersions(package);
    final downloadCounts = await app.metaStore
        .versionDownloadCounts(name, sorted.map((v) => v.version));
    var versions = [
      for (final v in sorted)
        DetailViewVersion(v.version, v.createdAt,
            isRetracted: v.isRetracted,
            downloads: downloadCounts[v.version] ?? 0,
            uploader: v.uploader),
    ];

    var pubspec = packageVersion.pubspec;
    List<String?> authors;
    if (pubspec['author'] is String) {
      authors = RegExp(r'<(.*?)>')
          .allMatches(pubspec['author'] as String)
          .map((match) => match.group(1))
          .toList();
    } else if (pubspec['authors'] is List) {
      authors = [
        for (final author in pubspec['authors'] as List)
          RegExp(r'<(.*?)>').firstMatch('$author')?.group(1),
      ];
    } else {
      authors = [];
    }

    final info = PubspecInfo(pubspec);
    final local = await app.metaStore.existingPackageNames([
      for (final dependency in [...info.dependencies, ...info.devDependencies])
        if (dependency.hosted && isValidPackageName(dependency.name))
          dependency.name,
    ]);
    List<Map<String, Object?>> dependencies(List<Dependency> list) => [
          for (final dependency in list)
            {
              'name': dependency.name,
              'constraint': dependency.constraint,
              'hosted': dependency.hosted,
              'local': local.contains(dependency.name),
            },
        ];
    String? url(String key) => switch (pubspec[key]) {
          final String text when text.trim().isNotEmpty => text.trim(),
          _ => null,
        };
    final links = markdownLinks(pubspec);
    String? html(String? source) => source == null || source.trim().isEmpty
        ? null
        : renderMarkdown(source, links: links).markup;

    var data = WebapiDetailView(
      package.name,
      packageVersion.version,
      info.description,
      url('homepage') ?? '',
      package.uploaders ?? [],
      packageVersion.createdAt,
      packageVersion.readme,
      packageVersion.changelog,
      versions,
      authors,
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

    return okWithJson({
      'data': {
        ...data.toJson(),
        'versions': [
          for (final (index, entry) in versions.indexed)
            {
              ...entry.toJson(),
              'published': sorted[index].createdAt.toUtc().toIso8601String(),
              'retracted': entry.isRetracted,
              'prerelease': _parse(entry.version).isPreRelease,
            },
        ],
        'latest': package.latest.version,
        'published': packageVersion.createdAt.toUtc().toIso8601String(),
        'uploader': packageVersion.uploader,
        'readmeHtml': html(packageVersion.readme),
        'changelogHtml': html(packageVersion.changelog),
        'dependencies': dependencies(info.dependencies),
        'devDependencies': dependencies(info.devDependencies),
        'environment': {
          'sdk': info.sdkConstraint,
          'flutter': info.flutterConstraint,
        },
        'platforms': info.platforms,
        'retracted': packageVersion.isRetracted,
        'archiveSha256': packageVersion.sha256,
        'private': package.private,
        'isFlutter': info.isFlutter,
        'homepage': url('homepage'),
        'repository': url('repository'),
        'issueTracker': url('issue_tracker'),
        'documentation': url('documentation'),
        'license': url('license'),
      },
    });
  }
}
