import 'dart:io';

import 'package:test/test.dart';
import 'package:unpub/unpub.dart';

import 'harness.dart';

void main() {
  final h = Harness()..install();

  Future<void> record(String action,
          {required DateTime at, String actor = 'a@b.c', String? package}) =>
      h.audit.record(AuditEvent(
          at: at,
          actor: actor,
          actorKind: AuditActorKind.session,
          action: action,
          package: package));

  group('events', () {
    test('a publish records the package, version and token', () async {
      final publisher = await h.user('p@b.c', Role.publisher);
      final secret = await h.token(publisher);
      await h.publish('fresh', '1.0.0', bearer: secret);
      final event = (await h.auditEvents('package.published')).single;
      expect(event['actor'], 'p@b.c');
      expect(event['actorKind'], 'apiToken');
      expect(event['token'], secret.substring(0, 8));
      expect(event['package'], 'fresh');
      expect(event['version'], '1.0.0');
      expect(event['at'], isA<DateTime>());
      expect(event['details']['sha256'], hasLength(64));
    });

    test('role, disable and enable are separate actions', () async {
      final admin = await h.user('a@b.c', Role.admin);
      final other = await h.user('o@b.c', Role.reader);
      final by = AuditContext(admin.email, kind: AuditActorKind.session);
      await h.accounts.updateUser(other, role: Role.publisher, by: by);
      await h.accounts.updateUser(other, disabled: true, by: by);
      await h.accounts.updateUser(other, disabled: false, by: by);
      final role = (await h.auditEvents('user.role_changed')).single;
      expect(role['target'], 'o@b.c');
      expect(role['details'], {'from': 'reader', 'to': 'publisher'});
      expect(role['actorKind'], 'session');
      expect(await h.auditEvents('user.disabled'), hasLength(1));
      expect(await h.auditEvents('user.enabled'), hasLength(1));
    });

    test('a failed login is anonymous', () async {
      await h.user('a@b.c', Role.admin);
      await h.accounts.login(email: 'a@b.c', password: 'wrong-password');
      final event = (await h.auditEvents('user.login_failed')).single;
      expect(event['actorKind'], 'anonymous');
      expect(event['actor'], 'a@b.c');
    });
  });

  group('GET /webapi/audit', () {
    late String adminToken;

    setUp(() async {
      adminToken = await h.token(await h.user('a@b.c', Role.admin));
      final start = DateTime.utc(2026, 1, 1);
      for (var day = 0; day < 10; day++) {
        await record(day.isEven ? 'package.published' : 'version.retracted',
            at: start.add(Duration(days: day)),
            actor: day < 5 ? 'one@b.c' : 'two@b.c',
            package: day % 3 == 0 ? 'alpha' : 'beta');
      }
    });

    Future<Reply> audit(String query, {String? bearer}) =>
        h.send('GET', '/webapi/audit$query', bearer: bearer ?? adminToken);

    test('needs an administrator', () async {
      expect((await h.send('GET', '/webapi/audit')).status,
          HttpStatus.unauthorized);
      final publisher = await h.token(await h.user('p@b.c', Role.publisher));
      expect((await audit('', bearer: publisher)).status, HttpStatus.forbidden);
      final reader = await h.token(await h.user('r@b.c', Role.reader));
      expect((await audit('', bearer: reader)).status, HttpStatus.forbidden);
      final publishOnly = await h.token(
          await h.accounts.requireUserByEmail('a@b.c'),
          scopes: {Scope.publish});
      expect(
          (await audit('', bearer: publishOnly)).status, HttpStatus.forbidden);
    });

    test('lists newest first, with the creation of the token', () async {
      final reply = await audit('');
      expect(reply.status, HttpStatus.ok);
      final events = reply.json['items'] as List;
      expect(reply.json['total'], 12);
      expect(events.first['action'], 'token.created');
      final times = [for (final e in events) DateTime.parse(e['at'] as String)];
      for (var i = 1; i < times.length; i++) {
        expect(times[i].isAfter(times[i - 1]), isFalse);
      }
    });

    test('filters by action, actor, package and time', () async {
      Future<List<String>> days(String query) async {
        final reply = await audit(query);
        expect(reply.status, HttpStatus.ok, reason: reply.body);
        return [
          for (final event in reply.json['items'] as List)
            (event['at'] as String).substring(0, 10),
        ];
      }

      expect(await days('?action=version.retracted'), hasLength(5));
      expect(await days('?actor=two%40b.c'), hasLength(5));
      expect(await days('?package=alpha'),
          ['2026-01-10', '2026-01-07', '2026-01-04', '2026-01-01']);
      expect(await days('?from=2026-01-03&to=2026-01-04'),
          ['2026-01-04', '2026-01-03']);
      expect(await days('?from=2026-01-03T00:00:00Z&to=2026-01-04T00:00:00Z'),
          ['2026-01-03']);
      expect(
          await days('?action=package.published&actor=one%40b.c&package=alpha'),
          hasLength(1));
    });

    test('filters the events of a token', () async {
      final reply = await audit('?actor=token:${adminToken.substring(0, 8)}');
      // The listing was not recorded, so nothing was done with the token.
      expect(reply.json['total'], 0);
    });

    test('pages', () async {
      final first = await audit('?size=5');
      final third = await audit('?size=5&page=3');
      expect((first.json['items'] as List), hasLength(5));
      expect((third.json['items'] as List), hasLength(2));
      expect(third.json['total'], 12);
      expect(third.json['page'], 3);
      expect((await audit('?size=201')).status, HttpStatus.badRequest);
      expect((await audit('?size=200')).status, HttpStatus.ok);
      expect((await audit('?page=0')).status, HttpStatus.badRequest);
      expect((await audit('?from=yesterday')).status, HttpStatus.badRequest);
    });
  });

  group('retention', () {
    Future<Map<String, dynamic>?> ttl() async {
      final indexes = await h.db.collection(auditCollection).getIndexes();
      return indexes.cast<Map<String, dynamic>?>().firstWhere(
          (index) => index!['name'] == auditRetentionIndex,
          orElse: () => null);
    }

    test('follows the configuration', () async {
      expect(await ttl(), isNull);

      await h.audit.ensureIndexes(retention: const Duration(days: 30));
      expect((await ttl())!['expireAfterSeconds'], 30 * 86400);
      expect((await ttl())!['key'], {'at': 1});

      await h.audit.ensureIndexes(retention: const Duration(days: 7));
      expect((await ttl())!['expireAfterSeconds'], 7 * 86400);

      await h.audit.ensureIndexes(retention: const Duration(days: 7));
      expect((await ttl())!['expireAfterSeconds'], 7 * 86400);

      await h.audit.ensureIndexes();
      expect(await ttl(), isNull);
    });

    test('works on a collection that does not exist yet', () async {
      await h.db.dropCollection(auditCollection);
      await h.audit.ensureIndexes(retention: const Duration(days: 1));
      expect((await ttl())!['expireAfterSeconds'], 86400);
    });

    test('is configured in days', () {
      final config =
          Config.parse('audit:\n  retentionDays: 90\n', environment: const {});
      expect(config.audit.retention, const Duration(days: 90));
      expect(Config.parse(null, environment: const {}).audit.retention, isNull);
      expect(
          Config.parse(null,
                  environment: const {'UNPUB_AUDIT_RETENTION_DAYS': '5'})
              .audit
              .retentionDays,
          5);
      expect(() => Config.parse('audit:\n  retentionDays: -1\n'),
          throwsA(isA<ConfigException>()));
    });
  });

  group('the audit page', () {
    test('is for administrators with a session', () async {
      await h.user('a@b.c', Role.admin);
      await h.user('p@b.c', Role.publisher);
      final publisher = await h.logIn('p@b.c');
      expect((await h.page('/admin/audit', as: publisher)).status,
          HttpStatus.forbidden);
      final anonymous = await h.page('/admin/audit');
      expect(anonymous.status, HttpStatus.seeOther);
      expect(anonymous.location, startsWith('/login'));
      final token = await h.token(await h.accounts.requireUserByEmail('a@b.c'));
      expect(
          (await h.send('GET', '/admin/audit', bearer: token, html: true))
              .status,
          HttpStatus.forbidden);
    });

    test('filters and pages', () async {
      await h.user('a@b.c', Role.admin);
      final browser = await h.logIn('a@b.c');
      for (var i = 0; i < 60; i++) {
        await record('package.published',
            at: DateTime.utc(2026, 2, 1).add(Duration(minutes: i)),
            package: 'alpha');
      }
      await record('version.retracted',
          at: DateTime.utc(2026, 2, 2), package: '<b>beta</b>');

      final all = await h.page('/admin/audit?package=alpha', as: browser);
      expect(all.status, HttpStatus.ok);
      expect(all.body, contains('60 events'));
      expect(all.body, contains('value="alpha"'));
      expect(
          all.body, contains('href="/admin/audit?package=alpha&amp;page=2"'));
      final second =
          await h.page('/admin/audit?package=alpha&page=2', as: browser);
      expect(RegExp('<code>package.published</code>').allMatches(second.body),
          hasLength(10));

      final escaped =
          await h.page('/admin/audit?action=version.retracted', as: browser);
      expect(escaped.body, contains('&lt;b&gt;beta&lt;/b&gt;'));
      expect(escaped.body, isNot(contains('<b>beta</b>')));

      final bad = await h.page('/admin/audit?from=soon', as: browser);
      expect(bad.status, HttpStatus.badRequest);
      expect(bad.body, contains('ISO 8601'));
    });

    test('pages keep the date window and the page size', () async {
      await h.user('a@b.c', Role.admin);
      final browser = await h.logIn('a@b.c');
      for (var i = 0; i < 12; i++) {
        await record('package.published',
            at: DateTime.utc(2026, 2, 1).add(Duration(hours: i * 4)),
            package: 'alpha');
      }
      // Outside the window.
      await record('package.published', at: DateTime.utc(2026, 1, 31, 23));
      await record('package.published', at: DateTime.utc(2026, 2, 3));

      final first = await h.page(
          '/admin/audit?from=2026-02-01&to=2026-02-02&size=5',
          as: browser);
      expect(first.status, HttpStatus.ok);
      expect(first.body, contains('12 events'));
      const next = '/admin/audit?from=2026-02-01&amp;to=2026-02-02'
          '&amp;size=5&amp;page=2';
      expect(first.body, contains('href="$next"'));
      // The date inputs show the days asked for, and the form keeps the
      // size.
      expect(first.body, contains('name="from" value="2026-02-01"'));
      expect(first.body, contains('name="to" value="2026-02-02"'));
      expect(first.body, contains('name="size" value="5"'));

      final second = await h.page(next.replaceAll('&amp;', '&'), as: browser);
      expect(second.body, contains('12 events'));
      expect(RegExp('<code>package.published</code>').allMatches(second.body),
          hasLength(5));
      expect(second.body, contains('name="from" value="2026-02-01"'));
      expect(second.body, contains('name="to" value="2026-02-02"'));

      // A bound with a time stays a time, and the default size is left out.
      final timed = await h.page(
          '/admin/audit?from=2026-02-01T08:00:00Z&to=2026-02-01T20:00:00Z',
          as: browser);
      expect(timed.body, contains('3 events'));
      expect(timed.body, isNot(contains('name="size"')));
      expect(const AuditQuery(page: 2).parameters, isEmpty);
      expect(
          AuditQuery.fromParameters(const {
            'from': '2026-02-01T08:00:00Z',
            'to': '2026-02-01T20:00:00Z',
          }).parameters,
          {
            'from': '2026-02-01T08:00:00.000Z',
            'to': '2026-02-01T20:00:00.000Z',
          });
      expect(
          AuditQuery.fromParameters(const {
            'from': '2026-02-01T00:00:00Z',
            'to': '2026-02-03T00:00:00Z',
          }).parameters,
          {'from': '2026-02-01', 'to': '2026-02-02'});
    });

    test('is linked from the admin pages of a package', () async {
      final admin = await h.user('a@b.c', Role.admin);
      await h.publish('alpha', '1.0.0', bearer: await h.token(admin));
      final browser = await h.logIn('a@b.c');
      final page = await h.page('/admin/packages/alpha', as: browser);
      expect(page.body, contains('href="/admin/audit?package=alpha"'));
      expect(page.body, contains('href="/admin/audit"'));
    });
  });

  test('old events without the new fields still read', () async {
    await h.db.collection(auditCollection).insertOne({
      'at': DateTime.utc(2025),
      'actor': 'token:abcdefgh',
      'action': 'package.published',
      'target': 'old@1.0.0',
      'details': {'uploader': 'x@b.c'},
      'ip': null,
    });
    final page = await h.audit.query(const AuditQuery());
    expect(page.events.single.target, 'old@1.0.0');
    expect(page.events.single.actorKind, 'system');
  });
}
