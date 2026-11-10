import '../../models.dart';
import '../html.dart';
import '../layout.dart';
import '../markdown.dart';
import '../pubspec_info.dart';
import 'package_list_page.dart';

enum PackageTab {
  readme('README'),
  changelog('Changelog'),
  versions('Versions'),
  install('Install');

  final String label;

  const PackageTab(this.label);

  static PackageTab parse(String? name) =>
      values.asNameMap()[name] ?? PackageTab.readme;
}

/// Everything the page of a package, or of one of its versions, shows.
class PackageView {
  final UnpubPackage package;

  /// The version shown: the one in the URL, or the latest.
  final UnpubVersion version;

  /// Whether the URL names [version], rather than showing the latest.
  final bool versionPage;

  /// Newest first.
  final List<UnpubVersion> versions;
  final Map<String, int> versionDownloads;

  /// The dependencies that are packages on this server.
  final Set<String> localPackages;

  final PackageTab tab;

  /// The URL clients use as the hosted URL of this server, without a slash
  /// at the end.
  final String hostedUrl;

  /// The registry unknown packages come from, such as https://pub.dev.
  final Uri upstream;

  /// Whether reading needs a token, which the install steps then mention.
  final bool authenticatedReads;

  const PackageView({
    required this.package,
    required this.version,
    required this.versionPage,
    required this.versions,
    required this.versionDownloads,
    required this.localPackages,
    required this.tab,
    required this.hostedUrl,
    required this.upstream,
    required this.authenticatedReads,
  });

  String get name => package.name;

  String get basePath =>
      versionPage ? versionHref(name, version.version) : packageHref(name);

  String tabHref(PackageTab tab) =>
      tab == PackageTab.readme ? basePath : '$basePath?tab=${tab.name}';

  String get upstreamHost =>
      upstream.host.isEmpty ? '$upstream' : upstream.host;

  Uri upstreamPackage(String name) =>
      upstream.resolve('/packages/${Uri.encodeComponent(name)}');
}

Html packagePage(PageContext context, PackageView view) {
  final version = view.version;
  final latest = view.package.latest;
  final info = PubspecInfo(version.pubspec);
  final title =
      view.versionPage ? '${view.name} ${version.version}' : view.name;
  return layout(context, title: title, body: [
    el('div', {
      'class': 'package-header'
    }, [
      el('h1', const {}, [
        view.name,
        ' ',
        el('span', {'class': 'muted'}, version.version),
        ' ',
        packageBadges(view.package, version.pubspec),
        if (version.isRetracted)
          el('span', {'class': 'badge retracted'}, 'Retracted'),
      ]),
      if (info.description.isNotEmpty) el('p', const {}, info.description),
      el('p', {
        'class': 'meta'
      }, [
        el('span', const {}, ['Published ', timeElement(version.createdAt)]),
        if (version.uploader != null)
          el('span', const {}, ['by ', version.uploader]),
        el('span', const {}, ['${view.package.download ?? 0} downloads']),
      ]),
    ]),
    if (view.package.isDiscontinued) _discontinuedNotice(view),
    if (version.isRetracted)
      el('p', {
        'class': 'error warning'
      }, [
        'This version was retracted',
        if (version.retractedAt != null)
          [' on ', timeElement(version.retractedAt)],
        '. Clients only use it when it is already locked.',
      ]),
    if (view.versionPage && version.version != latest.version)
      el('p', {
        'class': 'notice warning'
      }, [
        'This is not the latest version. The latest is ',
        el('a', {'href': versionHref(view.name, latest.version)},
            latest.version),
        '.',
      ]),
    el('div', {
      'class': 'detail'
    }, [
      el('div', const {}, [
        el('nav', {
          'aria-label': 'Package sections'
        }, [
          el('ul', {
            'class': 'tabs'
          }, [
            for (final tab in PackageTab.values)
              el('li', const {}, [
                el(
                    'a',
                    {
                      'href': view.tabHref(tab),
                      'aria-current': tab == view.tab ? 'page' : null,
                    },
                    tab.label),
              ]),
          ]),
        ]),
        el(
            'section',
            {'aria-label': view.tab.label},
            switch (view.tab) {
              PackageTab.readme =>
                _markdown(version.readme, 'README', version.pubspec),
              PackageTab.changelog =>
                _markdown(version.changelog, 'CHANGELOG', version.pubspec),
              PackageTab.versions => _versions(view),
              PackageTab.install => _install(view),
            }),
      ]),
      el('aside', {'class': 'sidebar', 'aria-label': 'Package details'},
          _sidebar(view, info)),
    ]),
  ]);
}

Html _discontinuedNotice(PackageView view) {
  final replacement = view.package.replacedBy;
  return el('p', {
    'class': 'error warning'
  }, [
    'This package is discontinued',
    if (view.package.discontinuedAt != null)
      [' since ', timeElement(view.package.discontinuedAt)],
    if (replacement != null)
      [
        '. Use ',
        el('a', {'href': packageHref(replacement)}, replacement),
        ' instead',
      ],
    '.',
  ]);
}

Html _markdown(String? source, String file, Map<String, dynamic> pubspec) {
  if (source == null || source.trim().isEmpty) {
    return el('p', {'class': 'muted'}, 'This version has no $file.md.');
  }
  return el('div', {'class': 'markdown'},
      renderMarkdown(source, links: markdownLinks(pubspec)));
}

/// Forges whose project pages are repositories, for a `homepage`.
const _forges = {'github.com', 'gitlab.com'};

/// Where links relative to the README and CHANGELOG of [pubspec] lead: its
/// `repository`, or a `homepage` on GitHub or GitLab, if it is https.
MarkdownLinks? markdownLinks(Map<String, dynamic> pubspec) {
  Uri? url(String key) => switch (pubspec[key]) {
        final String text => Uri.tryParse(text.trim()),
        _ => null,
      };
  final repository = MarkdownLinks.forRepository(url('repository'));
  if (repository != null) return repository;
  final homepage = url('homepage');
  if (homepage == null || !_forges.contains(homepage.host.toLowerCase())) {
    return null;
  }
  return MarkdownLinks.forRepository(homepage);
}

Html _versions(PackageView view) => el('div', {
      'class': 'table-scroll'
    }, [
      el('table', const {}, [
        el('caption', {'class': 'visually-hidden'}, 'Versions of ${view.name}'),
        el('thead', const {}, [
          el('tr', const {}, [
            for (final heading in [
              'Version',
              'Published',
              'Uploader',
              'Downloads',
              'SHA-256',
            ])
              el('th', {'scope': 'col'}, heading),
          ]),
        ]),
        el('tbody', const {}, [
          for (final item in view.versions)
            el('tr', const {}, [
              el('td', const {}, [
                el('a', {'href': versionHref(view.name, item.version)},
                    item.version),
                if (item.isRetracted)
                  [
                    ' ',
                    el('span', {'class': 'badge retracted'}, 'Retracted'),
                  ],
              ]),
              el('td', const {}, timeElement(item.createdAt)),
              el('td', const {}, item.uploader ?? '–'),
              el('td', const {}, '${view.versionDownloads[item.version] ?? 0}'),
              el('td', const {}, [
                if (item.sha256 case final hash?)
                  el('code', {'title': hash},
                      hash.length > 12 ? hash.substring(0, 12) : hash)
                else
                  '–',
              ]),
            ]),
        ]),
      ]),
    ]);

Html _snippet(String id, String label, String text) {
  return Html.join([
    el('h3', const {}, label),
    el('div', {
      'class': 'snippet'
    }, [
      el('pre', const {}, [
        el('code', {'id': id}, text)
      ]),
      el('button', {'type': 'button', 'class': 'copy', 'data-copy': id},
          'Copy'),
    ]),
  ]);
}

Html _install(PackageView view) {
  final constraint = '^${view.package.latest.version}';
  final flutter = PubspecInfo(view.version.pubspec).isFlutter;
  final add = flutter ? 'flutter pub add' : 'dart pub add';
  return Html.join([
    if (view.authenticatedReads) ...[
      el('p', const {}, [
        'This server needs a token to read packages. Create one on your ',
        el('a', {'href': '/account'}, 'account page'),
        ' and add it to the pub client once:',
      ]),
      _snippet('install-token', 'Add a token',
          'dart pub token add ${view.hostedUrl}'),
    ],
    _snippet('install-add', 'With ${flutter ? 'Flutter' : 'Dart'}',
        '$add ${view.name} --hosted-url ${view.hostedUrl}'),
    if (!flutter)
      _snippet('install-flutter', 'With Flutter',
          'flutter pub add ${view.name} --hosted-url ${view.hostedUrl}'),
    _snippet(
        'install-pubspec',
        'In pubspec.yaml',
        'dependencies:\n'
            '  ${view.name}:\n'
            '    hosted: ${view.hostedUrl}\n'
            '    version: $constraint'),
    el('p', {
      'class': 'muted'
    }, [
      'Or set ',
      el('code', const {}, 'PUB_HOSTED_URL=${view.hostedUrl}'),
      ' to use this server for every package it has.',
    ]),
  ]);
}

Html _sidebar(PackageView view, PubspecInfo info) {
  final latest = view.package.latest;
  final dependencies = info.dependencies;
  final platforms = info.platforms;
  final uploaders = view.package.uploaders ?? const [];
  return Html.join([
    el('h3', const {}, 'Latest version'),
    el('p', const {}, [
      el('a', {'href': packageHref(view.name)}, latest.version),
      ' · ',
      timeElement(latest.createdAt),
    ]),
    if (info.sdkConstraint != null || info.flutterConstraint != null) ...[
      el('h3', const {}, 'SDK constraints'),
      el('ul', const {}, [
        if (info.sdkConstraint case final sdk?)
          el('li', const {}, ['Dart ', el('code', const {}, sdk)]),
        if (info.flutterConstraint case final constraint?)
          el('li', const {}, ['Flutter ', el('code', const {}, constraint)]),
      ]),
    ],
    if (platforms.isNotEmpty) ...[
      el('h3', const {}, 'Platforms'),
      el('p', const {}, [
        for (final platform in platforms)
          [
            el('span', {'class': 'badge'}, platform),
            ' '
          ],
      ]),
    ],
    if (info.links.isNotEmpty) ...[
      el('h3', const {}, 'Links'),
      el('ul', const {}, [
        for (final (label, url) in info.links)
          el('li', const {}, [
            el(
                'a',
                {
                  'href': '$url',
                  'rel': 'nofollow noopener',
                  'target': '_blank'
                },
                label),
          ]),
      ]),
    ],
    el('h3', const {}, 'Dependencies'),
    if (dependencies.isEmpty)
      el('p', {'class': 'muted'}, 'None')
    else
      el('ul', const {}, [
        for (final dependency in dependencies)
          el('li', const {}, [
            _dependencyLink(view, dependency),
            if (dependency.constraint case final constraint?)
              [' ', el('code', const {}, constraint)],
          ]),
      ]),
    if (uploaders.isNotEmpty) ...[
      el('h3', const {}, 'Uploaders'),
      el('ul', const {},
          [for (final email in uploaders) el('li', const {}, email)]),
    ],
    if (!view.package.private) ...[
      el('h3', const {}, 'Upstream'),
      el('p', const {}, [
        el(
            'a',
            {
              'href': '${view.upstreamPackage(view.name)}',
              'rel': 'noopener',
              'target': '_blank',
            },
            'View on ${view.upstreamHost}'),
      ]),
    ],
  ]);
}

Html _dependencyLink(PackageView view, Dependency dependency) {
  if (view.localPackages.contains(dependency.name)) {
    return el('a', {'href': packageHref(dependency.name)}, dependency.name);
  }
  if (!dependency.hosted) return Html.text(dependency.name);
  return el(
      'a',
      {
        'href': '${view.upstreamPackage(dependency.name)}',
        'rel': 'noopener',
        'target': '_blank',
        'title': 'On ${view.upstreamHost}',
      },
      dependency.name);
}
