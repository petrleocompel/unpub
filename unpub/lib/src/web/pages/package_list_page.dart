import '../../models.dart';
import '../../paging.dart';

export '../../paging.dart' show maxPageSize;
import '../../store/meta_store.dart';
import '../html.dart';
import '../layout.dart';
import '../pubspec_info.dart';

/// Default and largest number of packages on a page.
const defaultPageSize = 20;

/// The search, filters and page asked for in the query of a list request.
class PackageListRequest {
  final String? query;
  final SdkFilter? sdk;
  final bool includeDiscontinued;
  final PackageSort sort;

  /// One-based.
  final int page;
  final int size;

  const PackageListRequest({
    this.query,
    this.sdk,
    this.includeDiscontinued = false,
    this.sort = PackageSort.downloads,
    this.page = 1,
    this.size = defaultPageSize,
  });

  /// Reads the parameters leniently: anything unknown falls back to the
  /// default rather than failing the page.
  factory PackageListRequest.fromQuery(Map<String, String> query) {
    final text = query['q']?.trim();
    final size = parsePageNumber(query['size']) ?? defaultPageSize;
    final page = parsePageNumber(query['page']) ?? 1;
    final search = text == null || text.isEmpty ? null : text;
    final sort = PackageSort.values.asNameMap()[query['sort']];
    return PackageListRequest(
      query: search,
      sdk: SdkFilter.values.asNameMap()[query['sdk']],
      includeDiscontinued: query['discontinued'] == '1',
      sort: search == null
          ? (sort == null || sort == PackageSort.relevance
              ? PackageSort.downloads
              : sort)
          : sort ?? PackageSort.relevance,
      page: boundedPage(page),
      size: size.clamp(1, maxPageSize),
    );
  }

  PackageSearch get search => PackageSearch(
        text: query,
        sdk: sdk,
        includeDiscontinued: includeDiscontinued,
        sort: sort,
        page: page - 1,
        size: size,
      );

  PackageSort get _defaultSort =>
      query == null ? PackageSort.downloads : PackageSort.relevance;

  /// The query string of this request on [page], leaving out defaults.
  String queryFor({int? page}) {
    final parameters = {
      if (query != null) 'q': query!,
      if (sdk != null) 'sdk': sdk!.name,
      if (includeDiscontinued) 'discontinued': '1',
      if (sort != _defaultSort) 'sort': sort.name,
      if (size != defaultPageSize) 'size': '$size',
      if ((page ?? this.page) != 1) 'page': '${page ?? this.page}',
    };
    return parameters.isEmpty
        ? ''
        : '?${Uri(queryParameters: parameters).query}';
  }
}

/// Encodes [name] for a path segment. Package names never need it, but
/// versions can hold `+`.
String segment(String name) => Uri.encodeComponent(name);

String packageHref(String name) => '/packages/${segment(name)}';

String versionHref(String name, String version) =>
    '/packages/${segment(name)}/versions/${segment(version)}';

/// The badges for the SDK and the state of a package.
Html packageBadges(UnpubPackage package, Map<String, dynamic> pubspec) {
  final info = PubspecInfo(pubspec);
  return Html.join([
    if (info.isFlutter)
      el('span', {'class': 'badge flutter'}, 'Flutter')
    else
      el('span', {'class': 'badge dart'}, 'Dart'),
    if (package.isDiscontinued)
      el('span', {'class': 'badge discontinued'}, 'Discontinued'),
    if (!package.private) el('span', {'class': 'badge proxied'}, 'Proxied'),
  ]);
}

Html _option(String value, String label, bool selected) =>
    el('option', {'value': value, 'selected': selected}, label);

Html _filters(PackageListRequest request) => el('form', {
      'id': 'search-form',
      'class': 'filters',
      'method': 'get',
      'action': '/packages',
      'role': 'search',
    }, [
      el('label', const {}, [
        'Search',
        el('input', {
          'type': 'search',
          'name': 'q',
          'value': request.query ?? '',
          'placeholder': 'Name or description',
          'autocomplete': 'off',
        }),
      ]),
      el('label', const {}, [
        'SDK',
        el('select', {
          'name': 'sdk'
        }, [
          _option('', 'Any', request.sdk == null),
          _option('dart', 'Dart', request.sdk == SdkFilter.dart),
          _option('flutter', 'Flutter', request.sdk == SdkFilter.flutter),
        ]),
      ]),
      el('label', const {}, [
        'Sort by',
        el('select', {
          'name': 'sort',
          'id': 'search-sort',
        }, [
          // Only a search has a relevance, which is then the default.
          if (request.query != null)
            _option('relevance', 'Relevance',
                request.sort == PackageSort.relevance),
          _option(
              'downloads', 'Downloads', request.sort == PackageSort.downloads),
          _option('updated', 'Recently updated',
              request.sort == PackageSort.updated),
          _option('name', 'Name', request.sort == PackageSort.name),
        ]),
      ]),
      el('label', {
        'class': 'check'
      }, [
        el('input', {
          'type': 'checkbox',
          'name': 'discontinued',
          'value': '1',
          'checked': request.includeDiscontinued,
        }),
        'Show discontinued',
      ]),
      if (request.size != defaultPageSize)
        el('input',
            {'type': 'hidden', 'name': 'size', 'value': '${request.size}'}),
      el('button', {'type': 'submit'}, 'Apply'),
    ]);

Html _packageItem(UnpubPackage package) {
  final latest = package.latest;
  final info = PubspecInfo(latest.pubspec);
  return el('li', const {}, [
    el('h2', const {}, [
      el('a', {'href': packageHref(package.name)}, package.name),
      packageBadges(package, latest.pubspec),
    ]),
    if (info.description.isNotEmpty) el('p', const {}, info.description),
    el('p', {
      'class': 'meta'
    }, [
      el('span', const {}, ['v', latest.version]),
      el('span', const {}, ['Updated ', timeElement(package.updatedAt)]),
      el('span', const {}, ['${package.download ?? 0} downloads']),
    ]),
  ]);
}

Html _pagination(PackageListRequest request, int count) => pagination(
    current: request.page,
    count: count,
    size: request.size,
    href: (page) => '/packages${request.queryFor(page: page)}');

/// Links to the pages of a list of [count] items, [size] on a page, the
/// address of each from [href], one-based.
Html pagination({
  required int current,
  required int count,
  required int size,
  required String Function(int page) href,
}) {
  final pages = (count / size).ceil();
  if (pages <= 1 && current == 1) return Html.empty;
  // The first, the last and a window around the current page.
  final shown = <int>{
    1,
    pages,
    for (var page = current - 2; page <= current + 2; page++)
      if (page >= 1 && page <= pages) page,
  }.toList()
    ..sort();
  final links = <Html>[];
  if (current > 1) {
    links.add(el('a', {'href': href(current - 1), 'rel': 'prev'}, 'Previous'));
  }
  int? previous;
  for (final page in shown) {
    if (page < 1) continue;
    if (previous != null && page > previous + 1) {
      links.add(el('span', {'class': 'gap'}, '…'));
    }
    links.add(page == current
        ? el('span', {'aria-current': 'page'}, '$page')
        : el('a', {'href': href(page)}, '$page'));
    previous = page;
  }
  if (current < pages) {
    links.add(el('a', {'href': href(current + 1), 'rel': 'next'}, 'Next'));
  }
  return el('nav', {'class': 'pagination', 'aria-label': 'Pages'}, links);
}

/// The results part of the list, which search-as-you-type replaces.
Html packageResults(PackageListRequest request, UnpubQueryResult result) {
  final first = (request.page - 1) * request.size + 1;
  final last = first + result.packages.length - 1;
  return Html.join([
    el(
        'p',
        {'class': 'muted', 'role': 'status'},
        result.count == 0
            ? (request.query == null
                ? 'No packages yet.'
                : 'No packages match “${request.query}”.')
            : result.packages.isEmpty
                ? 'No packages on page ${request.page}, there are ${result.count}.'
                : 'Showing $first–$last of ${result.count} '
                    '${result.count == 1 ? 'package' : 'packages'}.'),
    el('ol', {
      'class': 'package-list',
      'id': 'package-list',
      'start': first > 1 ? '$first' : null,
    }, [
      for (final package in result.packages) _packageItem(package),
    ]),
    _pagination(request, result.count),
  ]);
}

Html packageListPage(PageContext context, PackageListRequest request,
        UnpubQueryResult result) =>
    layout(context,
        title: request.query == null
            ? 'Packages'
            : 'Packages matching ${request.query}',
        body: [
          el('h1', const {}, 'Packages'),
          _filters(request),
          el('section', {'id': 'results', 'aria-live': 'polite'},
              packageResults(request, result)),
        ]);
