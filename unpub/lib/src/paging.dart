/// The pages of the list routes, bounded so that an offset never overflows.
library;

/// The highest one-based page of a list.
const maxPage = 100000;

/// The largest `size` of a page of a list route.
const maxPageSize = 100;

final _digits = RegExp(r'^[+-]?\d+$');

/// The integer [text] gives, or null if it is not one. Digits beyond the
/// range of an `int` read as its largest or smallest value, so that they
/// are bounded like any other number out of range rather than ignored.
int? parsePageNumber(String? text) {
  if (text == null) return null;
  final trimmed = text.trim();
  final value = int.tryParse(trimmed);
  if (value != null || !_digits.hasMatch(trimmed)) return value;
  return trimmed.startsWith('-') ? -_largest : _largest;
}

/// The largest `int` on every platform, including JavaScript.
const _largest = 9007199254740991;

/// [page], one-based, within 1 and [maxPage].
int boundedPage(int page) => page.clamp(1, maxPage);

/// How many items come before the one-based [page] of [size], with [page]
/// bounded by [boundedPage] and [size] taken as at least 1.
int pageOffset(int page, int size) =>
    (boundedPage(page) - 1) * (size < 1 ? 1 : size);

/// The one-based `page` and the `size` asked for in [query], read leniently:
/// a page that is not a positive number is the first, one above [maxPage] is
/// [maxPage] (beyond any real list, so an empty page), a size that is not a
/// positive number is [defaultSize], and a size is at most [maxSize].
({int page, int size}) pageParameters(Map<String, String> query,
    {int defaultSize = 20, int maxSize = maxPageSize}) {
  final page = parsePageNumber(query['page']) ?? 1;
  final size = parsePageNumber(query['size']) ?? defaultSize;
  return (page: boundedPage(page), size: size.clamp(1, maxSize));
}

/// A page of a list route: `{items, page, size, total}`.
Map<String, Object?> pageJson(Iterable<Object?> items,
        {required int page, required int size, required int total}) =>
    {
      'items': items.toList(),
      'page': page,
      'size': size,
      'total': total,
    };

/// The items of [all] on [page] of [size], bounded as by [pageOffset].
List<T> pageOf<T>(List<T> all, {required int page, required int size}) =>
    all.skip(pageOffset(page, size)).take(size < 1 ? 1 : size).toList();
