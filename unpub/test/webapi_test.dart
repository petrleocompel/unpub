import 'dart:io';

import 'package:intl/intl.dart';
import 'package:mongo_dart/mongo_dart.dart';
import 'package:test/test.dart';
import 'package:unpub/unpub.dart';

import 'harness.dart';
import 'markdown_attacks.dart';

const _bootstrap = 'bootstrap-secret-token';
const _sha256 =
    'abababababababababababababababababababababababababababababababab';

/// The JSON routes of the web client that read packages, and its config.
void main() {
  final harness =
      Harness(builder: (h) => h.buildApp(bootstrapToken: _bootstrap));
  harness.install();

  Future<void> addVersion(
    String name,
    String version, {
    String description = 'A package for the tests.',
    Map<String, Object> pubspec = const {},
    String? readme,
    String? changelog,
    String uploader = 'owner@example.com',
    DateTime? at,
    bool retracted = false,
    String? sha256 = _sha256,
  }) async {
    await harness.metaStore.addVersion(
        name,
        UnpubVersion(
          version,
          {
            'name': name,
            'version': version,
            'description': description,
            'environment': {'sdk': '^3.5.0'},
            ...pubspec,
          },
          null,
          uploader,
          readme,
          changelog,
          at ?? DateTime.now(),
          sha256: sha256,
        ));
    if (retracted) {
      await harness.metaStore
          .setVersionRetracted(name, version, retracted: true);
    }
  }

  Future<Reply> get(String path, {String? bearer, Browser? as, App? using}) =>
      harness.send('GET', path, bearer: bearer, as: as, using: using);

  /// Every kind of reader the matrix tries, by label, given the app.
  Future<Map<String, Future<Reply> Function(String path)>> readers(
      App using) async {
    final reader = await harness.user('reader@example.com', Role.reader);
    await harness.user('pub@example.com', Role.publisher);
    final admin = await harness.user('admin@example.com', Role.admin);
    final readerSession =
        await harness.apiLogIn('reader@example.com', using: using);
    final publisherSession =
        await harness.apiLogIn('pub@example.com', using: using);
    final adminSession =
        await harness.apiLogIn('admin@example.com', using: using);
    final readerToken = await harness.token(reader, scopes: {Scope.read});
    final adminToken = await harness.token(admin, scopes: {Scope.read});
    return {
      'reader session': (path) => get(path, as: readerSession, using: using),
      'publisher session': (path) =>
          get(path, as: publisherSession, using: using),
      'admin session': (path) => get(path, as: adminSession, using: using),
      'reader token': (path) => get(path, bearer: readerToken, using: using),
      'admin read token': (path) => get(path, bearer: adminToken, using: using),
      'bootstrap token': (path) => get(path, bearer: _bootstrap, using: using),
    };
  }

  group('GET /webapi/config', () {
    test('describes the server, without secrets', () async {
      final config = Config.parse('''
mongo:
  uri: mongodb://user:mongo-password@localhost:27017/dart_pub
metrics:
  token: metrics-secret
auth:
  bootstrapToken: $_bootstrap
''', environment: {});
      final app = harness.buildApp(
          config: config,
          ui: const UiConfig(assetsDir: 'test/fixtures/ui', mode: UiMode.spa));
      final reply = await get('/webapi/config', using: app);
      expect(reply.status, HttpStatus.ok);
      expect(reply.headers['cache-control'], 'no-store');
      final body = reply.json as Map<String, dynamic>;
      expect(
          body.keys,
          unorderedEquals([
            'version',
            'publicUrl',
            'readAccess',
            'accounts',
            'upstream',
            'features',
            'ui',
          ]));
      expect(body['version'], packageVersion);
      expect(body['publicUrl'], isNull);
      expect(body['readAccess'], 'public');
      expect(body['accounts'], isTrue);
      expect(body['upstream'],
          {'url': 'https://upstream.example', 'mode': 'redirect'});
      expect(body['features'],
          {'metrics': true, 'webhooks': false, 'spa': true, 'classic': true});
      expect(body['ui'],
          {'mode': 'spa', 'basePath': '', 'classicPath': '/classic'});
      for (final secret in ['mongo-password', 'metrics-secret', _bootstrap]) {
        expect(reply.body, isNot(contains(secret)));
      }
    });

    test('is open with readAccess authenticated', () async {
      final private = harness.buildApp(readAccess: ReadAccess.authenticated);
      final reply = await get('/webapi/config', using: private);
      expect(reply.status, HttpStatus.ok);
      expect(reply.json['readAccess'], 'authenticated');
      expect(reply.json['ui'],
          {'mode': 'ssr', 'basePath': '/app', 'classicPath': ''});
      expect(reply.json['features']['spa'], isFalse);
    });
  });

  group('GET /webapi/v2/packages', () {
    Future<Map<String, dynamic>> list([String query = '']) async {
      final reply = await get('/webapi/v2/packages$query');
      expect(reply.status, HttpStatus.ok, reason: reply.body);
      return reply.json as Map<String, dynamic>;
    }

    List<String> names(Map<String, dynamic> page) =>
        [for (final item in page['items'] as List) item['name'] as String];

    test('pages through package summaries', () async {
      final at = DateTime.utc(2026, 1, 2, 3, 4, 5);
      await addVersion('alpha', '1.0.0', description: 'First', at: at);
      await addVersion('alpha', '2.0.0-dev.1', at: at);
      await addVersion('beta', '0.1.0',
          pubspec: {
            'dependencies': {
              'flutter': {'sdk': 'flutter'},
            },
          },
          at: at);
      final page = await list();
      expect(page.keys, unorderedEquals(['items', 'page', 'size', 'total']));
      expect(page['page'], 1);
      expect(page['size'], 20);
      expect(page['total'], 2);
      final alpha = (page['items'] as List)
          .firstWhere((item) => item['name'] == 'alpha') as Map;
      expect(
          alpha.keys,
          unorderedEquals([
            'name',
            'latest',
            'description',
            'updatedAt',
            'downloads',
            'isDiscontinued',
            'replacedBy',
            'isFlutter',
            'private',
            'versionCount',
            'uploaders',
          ]));
      expect(alpha['versionCount'], 2);
      expect(alpha['uploaders'], ['owner@example.com']);
      expect(alpha['latest'], '1.0.0');
      expect(alpha['description'], 'First');
      expect(alpha['updatedAt'], '2026-01-02T03:04:05.000Z');
      expect(alpha['downloads'], 0);
      expect(alpha['isDiscontinued'], isFalse);
      expect(alpha['isFlutter'], isFalse);
      expect(alpha['private'], isTrue);
      final beta = (page['items'] as List)
          .firstWhere((item) => item['name'] == 'beta') as Map;
      expect(beta['isFlutter'], isTrue);

      final second = await list('?size=1&page=2&sort=name');
      expect(names(second), ['beta']);
      expect(second['size'], 1);
      expect(second['page'], 2);
      expect(second['total'], 2);
    });

    test('searches, filters and sorts as the package list does', () async {
      await addVersion('alpha', '1.0.0', description: 'A json parser');
      await addVersion('beta', '1.0.0',
          description: 'A json writer', pubspec: {'flutter': {}});
      await addVersion('gamma', '1.0.0', description: 'Old json');
      await harness.metaStore.setDiscontinued('gamma', discontinued: true);
      await harness.db
          .collection(packageCollection)
          .updateOne(where.eq('name', 'beta'), modify.set('download', 9));

      expect(names(await list('?q=json')), unorderedEquals(['alpha', 'beta']));
      expect(names(await list('?q=json&discontinued=true')),
          unorderedEquals(['alpha', 'beta', 'gamma']));
      expect(names(await list('?sdk=flutter')), ['beta']);
      expect(names(await list('?sdk=dart')), ['alpha']);
      expect(names(await list('?sort=downloads')), ['beta', 'alpha']);
      expect(names(await list('?sort=name&discontinued=true')),
          ['alpha', 'beta', 'gamma']);
      expect(names(await list('?q=writer')), ['beta']);
    });

    test('keeps the bounds of the list page', () async {
      await addVersion('alpha', '1.0.0');
      final big = await list('?size=1000&page=0');
      expect(big['size'], 100);
      expect(big['page'], 1);
      final lenient = await list('?size=x&page=y&sort=nonsense&sdk=go');
      expect(lenient['size'], 20);
      expect(lenient['page'], 1);
      expect(names(lenient), ['alpha']);
    });

    test('the legacy list keeps its shape', () async {
      await addVersion('alpha', '1.0.0');
      final reply = await get('/webapi/packages');
      expect(reply.json['data']['count'], 1);
      expect(reply.json['data']['packages'].single['name'], 'alpha');
    });
  });

  group('GET /webapi/package/<name>', () {
    const readme = '''
# Title

See [usage](doc/usage.md) and [the license](/LICENSE).

<script>alert(1)</script>
''';

    test('has the fields the package page shows', () async {
      await addVersion('helper', '1.0.0');
      await addVersion('alpha', '1.0.0',
          uploader: 'first@example.com',
          at: DateTime.utc(2026, 1, 1),
          readme: '# Old');
      await addVersion('alpha', '1.1.0',
          readme: readme,
          changelog: '## 1.1.0\n\n- Better.',
          uploader: 'second@example.com',
          at: DateTime.utc(2026, 2, 1),
          pubspec: {
            'repository': 'https://github.com/o/alpha',
            'issue_tracker': 'https://github.com/o/alpha/issues',
            'environment': {'sdk': '^3.5.0', 'flutter': '>=3.22.0'},
            'platforms': {'android': null, 'ios': null},
            'dependencies': {
              'helper': '^1.0.0',
              'http': {'version': '^1.0.0'},
              'flutter': {'sdk': 'flutter'},
              'local_thing': {'path': '../thing'},
            },
            'dev_dependencies': {'test': '^1.25.0'},
          });
      await addVersion('alpha', '2.0.0-dev.1', at: DateTime.utc(2026, 3, 1));
      await harness.metaStore
          .setVersionRetracted('alpha', '1.0.0', retracted: true);

      final reply = await get('/webapi/package/alpha');
      expect(reply.status, HttpStatus.ok, reason: reply.body);
      final data = reply.json['data'] as Map<String, dynamic>;
      expect(
          data.keys,
          containsAll([
            'name',
            'version',
            'latest',
            'description',
            'published',
            'uploader',
            'uploaders',
            'versions',
            'readmeHtml',
            'changelogHtml',
            'readme',
            'changelog',
            'dependencies',
            'devDependencies',
            'environment',
            'platforms',
            'retracted',
            'retractedAt',
            'isRetracted',
            'isDiscontinued',
            'replacedBy',
            'discontinuedAt',
            'archiveSha256',
            'downloads',
            'private',
            'isFlutter',
            'homepage',
            'repository',
            'issueTracker',
            'documentation',
            'license',
            'createdAt',
            'authors',
            'tags',
          ]));
      expect(data['name'], 'alpha');
      expect(data['version'], '1.1.0');
      expect(data['latest'], '1.1.0');
      expect(data['published'], '2026-02-01T00:00:00.000Z');
      expect(data['uploader'], 'second@example.com');
      expect(data['retracted'], isFalse);
      expect(data['archiveSha256'], 'ab' * 32);
      expect(data['private'], isTrue);
      expect(data['isFlutter'], isTrue);
      expect(data['downloads'], {'version': 0, 'package': 0});
      expect(data['environment'], {'sdk': '^3.5.0', 'flutter': '>=3.22.0'});
      expect(data['platforms'], ['android', 'ios']);
      expect(data['repository'], 'https://github.com/o/alpha');
      expect(data['issueTracker'], 'https://github.com/o/alpha/issues');
      expect(data['homepage'], isNull);
      expect(data['license'], isNull);
      expect(data['dependencies'], [
        {
          'name': 'helper',
          'constraint': '^1.0.0',
          'hosted': true,
          'local': true
        },
        {
          'name': 'http',
          'constraint': '^1.0.0',
          'hosted': true,
          'local': false
        },
        {
          'name': 'flutter',
          'constraint': null,
          'hosted': false,
          'local': false
        },
        {
          'name': 'local_thing',
          'constraint': null,
          'hosted': false,
          'local': false
        },
      ]);
      expect(data['devDependencies'], [
        {
          'name': 'test',
          'constraint': '^1.25.0',
          'hosted': true,
          'local': false
        },
      ]);

      final versions = data['versions'] as List;
      expect([for (final v in versions) v['version']],
          ['2.0.0-dev.1', '1.1.0', '1.0.0']);
      expect(
          (versions.first as Map).keys,
          containsAll([
            'version',
            'published',
            'uploader',
            'retracted',
            'prerelease',
            'downloads',
            'archiveSha256',
          ]));
      expect(versions[0]['prerelease'], isTrue);
      expect(versions[2]['retracted'], isTrue);
      expect(versions[2]['uploader'], 'first@example.com');
      expect(versions[2]['published'], '2026-01-01T00:00:00.000Z');

      // The README, rendered, sanitized and with its links in the repository.
      final html = data['readmeHtml'] as String;
      expect(html, contains('<h1 id="md-title">Title</h1>'));
      expect(html,
          contains('href="https://github.com/o/alpha/blob/HEAD/doc/usage.md"'));
      expect(html,
          contains('href="https://github.com/o/alpha/blob/HEAD/LICENSE"'));
      expect(html, isNot(contains('<script')));
      expectInert(html);
      expect(data['changelogHtml'], contains('<li>Better.</li>'));
      // The source stays for scripts.
      expect(data['readme'], readme);
    });

    test('of one version, and the same as latest', () async {
      await addVersion('alpha', '1.0.0', readme: '# One');
      await addVersion('alpha', '1.0.0+1', readme: '');
      final one = await get('/webapi/package/alpha/1.0.0');
      expect(one.json['data']['version'], '1.0.0');
      expect(one.json['data']['readmeHtml'], contains('One'));
      final build = await get('/webapi/package/alpha/1.0.0%2B1');
      expect(build.json['data']['version'], '1.0.0+1');
      expect(build.json['data']['readmeHtml'], isNull);
      expect(build.json['data']['changelogHtml'], isNull);
      final latest = await get('/webapi/package/alpha/latest');
      final plain = await get('/webapi/package/alpha');
      expect(latest.body, plain.body);
    });

    for (final MapEntry(key: name, value: source) in markdownAttacks.entries) {
      test('neutralizes $name in readmeHtml', () async {
        await addVersion('alpha', '1.0.0',
            readme: source,
            changelog: source,
            pubspec: {'repository': 'https://github.com/o/r'});
        final data = (await get('/webapi/package/alpha')).json['data'];
        expectInert(data['readmeHtml'] as String, reason: name);
        expectInert(data['changelogHtml'] as String, reason: name);
      });
    }

    test('lists the archive hash of every version, null when unknown',
        () async {
      await addVersion('alpha', '1.0.0', sha256: null);
      await addVersion('alpha', '1.1.0', sha256: 'cd' * 32);
      for (final path in [
        '/webapi/package/alpha',
        '/webapi/package/alpha/1.0.0',
      ]) {
        final versions = (await get(path)).json['data']['versions'] as List;
        expect({
          for (final v in versions) v['version']: v['archiveSha256']
        }, {
          '1.1.0': 'cd' * 32,
          '1.0.0': null
        }, reason: path);
        for (final v in versions) {
          expect((v as Map).containsKey('archiveSha256'), isTrue);
        }
      }
      expect(
          (await get('/webapi/package/alpha/1.0.0')).json['data']
              ['archiveSha256'],
          isNull);
    });

    test('a missing package or version is a 404 error', () async {
      await addVersion('alpha', '1.0.0');
      for (final path in [
        '/webapi/package/missing',
        '/webapi/package/missing/1.0.0',
        '/webapi/package/alpha/9.9.9',
        '/webapi/package/alpha/not-a-version',
        '/webapi/package/missing/stats',
      ]) {
        final reply = await get(path);
        expect(reply.status, HttpStatus.notFound, reason: path);
        expect(reply.json['error']['code'], 'not_found', reason: path);
        expect(reply.json['error']['message'], isA<String>());
      }
    });
  });

  group('GET /webapi/package/<name>/stats', () {
    test('fills the last 30 days and ranks every version', () async {
      await addVersion('alpha', '1.0.0');
      await addVersion('alpha', '1.1.0');
      await addVersion('alpha', '2.0.0');
      final today = DateTime.now();
      final yesterday = DateTime(today.year, today.month, today.day - 1);
      final key = DateFormat('yyyyMMdd');
      await harness.db.collection(statsCollection).updateOne(
          where.eq('name', 'alpha'),
          modify
              .set('d${key.format(today)}', 3)
              .set('d${key.format(yesterday)}', 2),
          upsert: true);
      await harness.db
          .collection(packageCollection)
          .updateOne(where.eq('name', 'alpha'), modify.set('download', 40));
      for (final (version, count) in [('1.0.0', 4), ('2.0.0', 7)]) {
        for (var i = 0; i < count; i++) {
          harness.metaStore.increaseDownloads('alpha', version);
        }
      }
      // The counters are written without waiting: wait until all are.
      Future<bool> counted() async {
        final package = await harness.packageDocument('alpha');
        final stats = await harness.db
            .collection(statsCollection)
            .findOne(where.eq('name', 'alpha'));
        final versions = await harness.metaStore
            .versionDownloadCounts('alpha', ['1.0.0', '2.0.0']);
        return package?['download'] == 40 + 11 &&
            stats?['d${key.format(today)}'] == 3 + 11 &&
            versions['1.0.0'] == 4 &&
            versions['2.0.0'] == 7;
      }

      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!await counted()) {
        expect(DateTime.now().isBefore(deadline), isTrue,
            reason: 'the download counters were not written');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      final reply = await get('/webapi/package/alpha/stats');
      expect(reply.status, HttpStatus.ok, reason: reply.body);
      final stats = reply.json as Map<String, dynamic>;
      expect(stats.keys,
          unorderedEquals(['name', 'total', 'recent', 'days', 'versions']));
      expect(stats['name'], 'alpha');
      final days = stats['days'] as List;
      expect(days, hasLength(30));
      final iso = DateFormat('yyyy-MM-dd');
      expect(days.last, {'day': iso.format(today), 'count': 3 + 7 + 4});
      expect(days[28], {'day': iso.format(yesterday), 'count': 2});
      expect(days.first['count'], 0);
      expect(days.where((day) => day['count'] == 0), hasLength(28));
      expect(stats['recent'], 16);
      expect(stats['total'], 40 + 11);
      expect(stats['versions'], [
        {'version': '2.0.0', 'downloads': 7},
        {'version': '1.0.0', 'downloads': 4},
        {'version': '1.1.0', 'downloads': 0},
      ]);
    });
  });

  group('readAccess authenticated', () {
    test('package reads need credentials, any reader may', () async {
      final private = harness.buildApp(
          readAccess: ReadAccess.authenticated, bootstrapToken: _bootstrap);
      await addVersion('alpha', '1.0.0');
      const paths = [
        '/webapi/v2/packages',
        '/webapi/package/alpha',
        '/webapi/package/alpha/1.0.0',
        '/webapi/package/alpha/stats',
      ];
      for (final path in paths) {
        final anonymous = await get(path, using: private);
        expect(anonymous.status, HttpStatus.unauthorized, reason: path);
        expect(anonymous.json['error']['code'], 'unauthorized');
      }
      for (final MapEntry(key: who, value: read)
          in (await readers(private)).entries) {
        for (final path in paths) {
          expect((await read(path)).status, HttpStatus.ok,
              reason: '$who $path');
        }
      }
    });
  });
}
