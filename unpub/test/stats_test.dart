import 'dart:io';

import 'package:html/parser.dart' as html_parser;
import 'package:intl/intl.dart';
import 'package:mongo_dart/mongo_dart.dart';
import 'package:test/test.dart';
import 'package:unpub/unpub.dart';

import 'package:unpub/src/web/download_stats.dart';

import 'harness.dart';

void main() {
  final h = Harness()..install();

  late String ownerToken;

  setUp(() async {
    ownerToken = await h.token(await h.user('owner@b.c', Role.publisher));
    await h.publish('alpha', '1.0.0', bearer: ownerToken);
    await h.publish('alpha', '1.1.0', bearer: ownerToken);
  });

  String day(DateTime date) => DateFormat('yyyyMMdd').format(date);

  final today = DateTime.now();

  Future<int?> countedToday() async {
    final stats = await h.db
        .collection(statsCollection)
        .findOne(where.eq('name', 'alpha'));
    return (stats?['d${day(today)}'] as num?)?.toInt();
  }

  /// Waits up to 2 seconds for the counting of a download, which does not
  /// hold up the response, to reach [expected], and then a little longer, so
  /// that counting too much shows too.
  Future<int?> settled([int? expected]) async {
    final budget = Stopwatch()..start();
    var counted = await countedToday();
    while (counted != expected && budget.elapsed < const Duration(seconds: 2)) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      counted = await countedToday();
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
    return countedToday();
  }

  group('a download', () {
    const path = '/packages/alpha/versions/1.0.0.tar.gz';
    const pub = {'user-agent': 'Dart pub 3.12.0'};

    test('by the pub client counts for today', () async {
      final reply = await h.send('GET', path, headers: pub);
      expect(reply.status, HttpStatus.ok);
      expect(await settled(1), 1);
      await h.send('GET', path, headers: pub);
      expect(await settled(2), 2);
    });

    test('is not counted for a HEAD, a 304 or another client', () async {
      final first = await h.send('HEAD', path, headers: pub);
      expect(first.status, HttpStatus.ok);
      final etag = first.headers['etag']!;
      final cached =
          await h.send('GET', path, headers: {...pub, 'if-none-match': etag});
      expect(cached.status, HttpStatus.notModified);
      await h.send('GET', path, headers: {'user-agent': 'curl/8'});
      expect(await settled(), isNull);
    });
  });

  group('the statistics page', () {
    setUp(() async {
      final stats = <String, Object>{'name': 'alpha'};
      for (var back = 0; back < 40; back++) {
        stats['d${day(DateTime(today.year, today.month, today.day - back))}'] =
            back + 1;
      }
      await h.db.collection(statsCollection).insertOne(stats);
      await h.db
          .collection(packageCollection)
          .updateOne(where.eq('name', 'alpha'), modify.set('download', 9999));
      await h.db.collection(versionStatsCollection).insertMany([
        {'name': 'alpha', 'version': '1.0.0', 'count': 7},
        {'name': 'alpha', 'version': '1.1.0', 'count': 70},
      ]);
    });

    test('shows the last 30 days, the totals and the top versions', () async {
      final page = await h.page('/packages/alpha/stats');
      expect(page.status, HttpStatus.ok);
      expect(page.headers['content-security-policy'], contentSecurityPolicy);
      final document = html_parser.parse(page.body);

      final tab = document.querySelector('a[aria-current="page"]')!;
      expect(tab.text, 'Stats');
      expect(tab.attributes['href'], '/packages/alpha/stats');

      final facts = document.querySelector('dl.facts')!.text;
      expect(facts, contains('9999'));
      // 1 + 2 + ... + 30.
      expect(facts, contains('465'));

      final tables = document.querySelectorAll('table');
      final days = tables.first.querySelectorAll('tbody tr');
      expect(days, hasLength(30));
      expect(days.first.querySelectorAll('td').last.text, '1');
      expect(days.first.querySelector('time')!.attributes['datetime'],
          DateFormat('yyyy-MM-dd').format(today));
      expect(days.last.querySelectorAll('td').last.text, '30');

      final versions = [
        for (final row in tables.last.querySelectorAll('tbody tr'))
          row.querySelectorAll('td').map((cell) => cell.text).toList(),
      ];
      expect(versions, [
        ['1.1.0', '70'],
        ['1.0.0', '7'],
      ]);
    });

    test('draws the chart as SVG without styles or scripts', () async {
      final page = await h.page('/packages/alpha/stats');
      final document = html_parser.parse(page.body);
      final svg = document.querySelector('svg.chart')!;
      final bars = svg.querySelectorAll('rect');
      expect(bars, hasLength(30));
      expect(bars.every((bar) => bar.classes.contains('bar')), isTrue);
      expect(bars.last.querySelector('title')!.text, endsWith(': 1'));
      final heights = [
        for (final bar in bars) int.parse(bar.attributes['height']!),
      ];
      // Oldest first: 30 downloads 29 days ago, 1 today.
      expect(heights.first, greaterThan(heights.last));
      expect(svg.outerHtml, isNot(contains('style')));
      expect(page.body, isNot(contains(' style=')));
      expect(
          document
              .querySelectorAll('script')
              .every((script) => script.attributes.containsKey('src')),
          isTrue);
      expect(svg.attributes['role'], 'img');
      expect(svg.children.first.localName, 'title');
      expect(svg.attributes['aria-labelledby'], svg.children.first.id);
      expect(svg.children[1].localName, 'desc');
      expect(svg.attributes['aria-describedby'], svg.children[1].id);
      expect(svg.children[1].text, contains('The most on one day were 30'));
    });

    test('is linked from every package page as a tab', () async {
      for (final path in [
        '/packages/alpha',
        '/packages/alpha?tab=versions',
        '/packages/alpha/versions/1.0.0',
      ]) {
        final page = await h.page(path);
        expect(page.body, contains('href="/packages/alpha/stats"'),
            reason: path);
      }
      final version = await h
          .send('GET', '/packages/alpha/versions/1.0.0?tab=stats', html: true);
      expect(version.status, HttpStatus.seeOther);
      expect(version.location, '/packages/alpha/stats');
    });

    test('of a package without downloads shows empty bars', () async {
      await h.publish('beta', '1.0.0', bearer: ownerToken);
      final page = await h.page('/packages/beta/stats');
      expect(page.status, HttpStatus.ok);
      final document = html_parser.parse(page.body);
      final bars = document.querySelectorAll('svg.chart rect');
      expect(bars.every((bar) => bar.classes.contains('empty')), isTrue);
      expect(page.body, contains('No version was downloaded yet.'));
    });

    test('of an unknown package is a 404', () async {
      expect(
          (await h.page('/packages/gamma/stats')).status, HttpStatus.notFound);
    });

    test('needs to log in when reads do', () async {
      final app = h.buildApp(readAccess: ReadAccess.authenticated);
      final anonymous = await h.page('/packages/alpha/stats', using: app);
      expect(anonymous.status, HttpStatus.seeOther);
      expect(anonymous.location, startsWith('/login'));
      await h.user('r@b.c', Role.reader);
      final reader = await h.logIn('r@b.c', using: app);
      expect(
          (await h.page('/packages/alpha/stats', as: reader, using: app))
              .status,
          HttpStatus.ok);
    });

    test('is linked from the admin page of the package', () async {
      await h.user('admin@b.c', Role.admin);
      final browser = await h.logIn('admin@b.c');
      final page = await h.page('/admin/packages/alpha', as: browser);
      expect(page.body, contains('href="/packages/alpha/stats"'));
    });
  });

  group('the chart', () {
    List<(DateTime, int)> days(Map<int, int> counts) => [
          for (var i = 0; i < statsDays; i++)
            (DateTime(2026, 10, 1 + i), counts[i] ?? 0),
        ];

    dynamic svgOf(List<(DateTime, int)> data) =>
        html_parser.parse(downloadChart(data).toString()).querySelector('svg')!;

    List<String> labels(dynamic svg) => [
          for (final text in svg.querySelectorAll('text')) text.text as String,
        ];

    test('of no downloads', () {
      final svg = svgOf(days(const {}));
      expect(svg.children.first.localName, 'title');
      expect(svg.children.first.text, contains('30 days'));
      expect(svg.children[1].localName, 'desc');
      expect(
          svg.children[1].text, 'No downloads from 2026-10-01 to 2026-10-30.');
      expect(labels(svg), ['max 0', '2026-10-01', '2026-10-30']);
      expect(svg.querySelectorAll('line.tick'), isEmpty);
      expect(
          svg
              .querySelectorAll('rect')
              .every((bar) => bar.classes.contains('empty') as bool),
          isTrue);
    });

    test('of one day with downloads', () {
      final svg = svgOf(days(const {4: 1}));
      expect(svg.children[1].text,
          startsWith('1 download from 2026-10-01 to 2026-10-30.'));
      expect(svg.children[1].text, contains('were 1, on 2026-10-05'));
      expect(labels(svg).first, 'max 1');
      // No room for a tick between 0 and 1.
      expect(svg.querySelectorAll('line.tick'), isEmpty);
      final bars = svg.querySelectorAll('rect');
      expect(bars.where((bar) => !(bar.classes.contains('empty') as bool)),
          hasLength(1));
    });

    test('of a million downloads', () {
      final svg = svgOf(days(const {0: 1000000, 29: 250000}));
      expect(labels(svg), containsAll(['max 1,000,000', '500,000']));
      expect(svg.children[1].text,
          contains('1,250,000 downloads from 2026-10-01'));
      expect(svg.children[1].text, contains('were 1,000,000, on 2026-10-01'));
      final tick = svg.querySelector('line.tick');
      final y = int.parse(tick.attributes['y1'] as String);
      // Halfway between the axis at 160 and the top bar at 16.
      expect(y, 88);
      final bars = svg.querySelectorAll('rect');
      expect(bars.first.querySelector('title').text, '2026-10-01: 1,000,000');
      expect(int.parse(bars.first.attributes['height'] as String), 144);
    });
  });
}
