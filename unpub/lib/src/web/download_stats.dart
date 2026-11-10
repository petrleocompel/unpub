import 'package:intl/intl.dart';

import '../store/meta_store.dart';
import 'html.dart';

/// How many days the statistics page shows.
const statsDays = 30;

/// How many versions the statistics page ranks.
const topVersionCount = 10;

final _dayKey = DateFormat('yyyyMMdd');

/// The downloads of one package, as the statistics page shows them.
class DownloadStats {
  /// The last [statsDays] days, oldest first, today included.
  final List<(DateTime, int)> days;

  /// Every download counted, from the package document.
  final int total;

  /// The most downloaded versions, most first.
  final List<(String, int)> topVersions;

  const DownloadStats(
      {required this.days, required this.total, required this.topVersions});

  int get recent => days.fold(0, (sum, day) => sum + day.$2);

  /// Reads the statistics of [name] from [store]. Days are those of the
  /// server's local time, as the counters are.
  static Future<DownloadStats> load(MetaStore store, String name,
      {required int total,
      required Iterable<String> versions,
      DateTime? now}) async {
    final today = now ?? DateTime.now();
    final dates = [
      for (var back = statsDays - 1; back >= 0; back--)
        DateTime(today.year, today.month, today.day - back),
    ];
    final counts = await store
        .dailyDownloads(name, [for (final d in dates) _dayKey.format(d)]);
    final byVersion = await store.versionDownloadCounts(name, versions);
    final ranked = [
      for (final MapEntry(:key, :value) in byVersion.entries)
        if (value > 0) (key, value),
    ]..sort(
        (a, b) => b.$2 != a.$2 ? b.$2.compareTo(a.$2) : a.$1.compareTo(b.$1));
    return DownloadStats(
      days: [for (final d in dates) (d, counts[_dayKey.format(d)] ?? 0)],
      total: total,
      topVersions: ranked.take(topVersionCount).toList(),
    );
  }
}

/// The day [date] in the ISO format, without converting it to UTC: the
/// counters are kept by local day.
String isoDay(DateTime date) => DateFormat('yyyy-MM-dd').format(date);

const _chartWidth = 600;
const _chartHeight = 160;
const _labelHeight = 16;

/// A bar chart of [days] drawn on the server: plain SVG with classes for the
/// stylesheet, no style attribute and no script, which the CSP would refuse.
Html downloadChart(List<(DateTime, int)> days) {
  final highest = days.fold(0, (top, day) => day.$2 > top ? day.$2 : top);
  final scale = highest == 0 ? 0.0 : (_chartHeight - _labelHeight) / highest;
  final slot = _chartWidth / days.length;
  final barWidth = (slot * 0.75).floor();
  return el('svg', {
    'class': 'chart',
    'viewBox': '0 0 $_chartWidth ${_chartHeight + _labelHeight}',
    'role': 'img',
    'aria-label': 'Downloads per day over the last ${days.length} days, at '
        'most $highest on one day',
    'xmlns': 'http://www.w3.org/2000/svg',
  }, [
    el('text', {'class': 'chart-label', 'x': '0', 'y': '12'}, 'max $highest'),
    for (final (index, (date, count)) in days.indexed)
      _bar(date, count,
          x: (index * slot).round(),
          width: barWidth,
          height: (count * scale).round()),
    el('line', {
      'class': 'axis',
      'x1': '0',
      'y1': '$_chartHeight',
      'x2': '$_chartWidth',
      'y2': '$_chartHeight',
    }),
    el(
        'text',
        {
          'class': 'chart-label',
          'x': '0',
          'y': '${_chartHeight + _labelHeight - 2}',
        },
        isoDay(days.first.$1)),
    el(
        'text',
        {
          'class': 'chart-label',
          'x': '$_chartWidth',
          'y': '${_chartHeight + _labelHeight - 2}',
          'text-anchor': 'end',
        },
        isoDay(days.last.$1)),
  ]);
}

/// One day of the chart. A day without downloads gets a sliver, so that it
/// still shows.
Html _bar(DateTime date, int count,
        {required int x, required int width, required int height}) =>
    el(
        'rect',
        {
          'class': count == 0 ? 'bar empty' : 'bar',
          'x': '$x',
          'y': '${_chartHeight - (height == 0 ? 1 : height)}',
          'width': '$width',
          'height': '${height == 0 ? 1 : height}',
        },
        el('title', const {}, '${isoDay(date)}: $count'));

/// The statistics section of a package page.
Html downloadStatsSection(String name, DownloadStats stats) => Html.join([
      el('dl', {
        'class': 'facts'
      }, [
        el('dt', const {}, 'Downloads in all'),
        el('dd', const {}, '${stats.total}'),
        el('dt', const {}, 'Last $statsDays days'),
        el('dd', const {}, '${stats.recent}'),
      ]),
      downloadChart(stats.days),
      el(
          'p',
          {'class': 'muted'},
          'Counted when the pub client downloads an archive, by day of the '
              'server.'),
      el('div', {
        'class': 'columns'
      }, [
        el('div', const {}, [
          el('h3', const {}, 'Per day'),
          el('div', {
            'class': 'table-scroll'
          }, [
            el('table', const {}, [
              el('caption', {'class': 'visually-hidden'},
                  'Downloads of $name per day'),
              el('thead', const {}, [
                el('tr', const {}, [
                  el('th', {'scope': 'col'}, 'Day'),
                  el('th', {'scope': 'col'}, 'Downloads'),
                ]),
              ]),
              el('tbody', const {}, [
                for (final (date, count) in stats.days.reversed)
                  el('tr', const {}, [
                    el('td', const {},
                        el('time', {'datetime': isoDay(date)}, isoDay(date))),
                    el('td', {'class': 'number'}, '$count'),
                  ]),
              ]),
            ]),
          ]),
        ]),
        el('div', const {}, [
          el('h3', const {}, 'Top versions'),
          if (stats.topVersions.isEmpty)
            el('p', {'class': 'muted'}, 'No version was downloaded yet.')
          else
            el('div', {
              'class': 'table-scroll'
            }, [
              el('table', const {}, [
                el('caption', {'class': 'visually-hidden'},
                    'Most downloaded versions of $name'),
                el('thead', const {}, [
                  el('tr', const {}, [
                    el('th', {'scope': 'col'}, 'Version'),
                    el('th', {'scope': 'col'}, 'Downloads'),
                  ]),
                ]),
                el('tbody', const {}, [
                  for (final (version, count) in stats.topVersions)
                    el('tr', const {}, [
                      el('td', const {}, version),
                      el('td', {'class': 'number'}, '$count'),
                    ]),
                ]),
              ]),
            ]),
        ]),
      ]),
    ]);
