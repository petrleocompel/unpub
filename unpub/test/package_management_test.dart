import 'dart:async';
import 'dart:io';

import 'package:mongo_dart/mongo_dart.dart';
import 'package:test/test.dart';
import 'package:unpub/unpub.dart';

import 'harness.dart';

void main() {
  final h = Harness()..install();

  late User admin;
  late String adminToken;
  late String ownerToken;

  setUp(() async {
    admin = await h.user('admin@b.c', Role.admin);
    adminToken = await h.token(admin);
    ownerToken = await h.token(await h.user('owner@b.c', Role.publisher));
  });

  Future<Reply> deleteVersion(String name, String version, {String? bearer}) =>
      h.send('DELETE', '/api/packages/$name/versions/$version', bearer: bearer);

  Future<Reply> deletePackage(String name, {String? bearer}) =>
      h.send('DELETE', '/api/packages/$name', bearer: bearer);

  List<String> versionsOf(Map<String, dynamic>? document) => [
        for (final item in document?['versions'] as List? ?? const [])
          item['version'] as String,
      ];

  group('deleting a version', () {
    setUp(() async {
      await h.publish('alpha', '1.0.0', bearer: ownerToken);
      await h.publish('alpha', '1.1.0', bearer: ownerToken);
    });

    test('is for administrators only', () async {
      expect((await deleteVersion('alpha', '1.0.0')).status,
          HttpStatus.unauthorized);
      final uploader =
          await deleteVersion('alpha', '1.0.0', bearer: ownerToken);
      expect(uploader.status, HttpStatus.forbidden);
      expect(uploader.json['error']['message'], 'administrator role required');
      final reader = await h.token(await h.user('r@b.c', Role.reader));
      expect((await deleteVersion('alpha', '1.0.0', bearer: reader)).status,
          HttpStatus.forbidden);
      final readOnlyAdmin = await h.token(admin, scopes: {Scope.read});
      expect(
          (await deleteVersion('alpha', '1.0.0', bearer: readOnlyAdmin)).status,
          HttpStatus.forbidden);
      expect(versionsOf(await h.packageDocument('alpha')), hasLength(2));
    });

    test('removes the version, its counts and its archive', () async {
      await h.db.collection(versionStatsCollection).insertMany([
        {'name': 'alpha', 'version': '1.0.0', 'count': 3},
        {'name': 'alpha', 'version': '1.1.0', 'count': 4},
      ]);
      expect(h.storedArchives(), hasLength(2));

      final reply = await deleteVersion('alpha', '1.1.0', bearer: adminToken);
      expect(reply.status, HttpStatus.ok, reason: reply.body);
      expect(reply.json['success']['message'], 'version deleted');

      expect(versionsOf(await h.packageDocument('alpha')), ['1.0.0']);
      final stats =
          await h.db.collection(versionStatsCollection).find().toList();
      expect([for (final item in stats) item['version']], ['1.0.0']);
      expect(h.storedArchives().single, contains('alpha-1.0.0-'));

      final listing = await h.send('GET', '/api/packages/alpha');
      expect(listing.json['latest']['version'], '1.0.0');
      expect((await h.send('GET', '/api/packages/alpha/versions/1.1.0')).status,
          HttpStatus.notFound);

      final event = (await h.auditEvents('version.deleted')).single;
      expect(event['package'], 'alpha');
      expect(event['version'], '1.1.0');
      expect(event['actor'], 'admin@b.c');
      expect(event['details']['archiveDeleted'], isTrue);
    });

    test('refuses the last version', () async {
      expect((await deleteVersion('alpha', '1.0.0', bearer: adminToken)).status,
          HttpStatus.ok);
      final last = await deleteVersion('alpha', '1.1.0', bearer: adminToken);
      expect(last.status, HttpStatus.conflict);
      expect(last.json['error']['message'],
          contains('DELETE /api/packages/alpha'));
      expect(versionsOf(await h.packageDocument('alpha')), ['1.1.0']);
    });

    test('of an unknown package or version is a 404', () async {
      expect((await deleteVersion('beta', '1.0.0', bearer: adminToken)).status,
          HttpStatus.notFound);
      expect((await deleteVersion('alpha', '9.0.0', bearer: adminToken)).status,
          HttpStatus.notFound);
    });

    test('keeps an object another record still names', () async {
      final document = (await h.packageDocument('alpha'))!;
      final digest = (document['versions'] as List)
          .firstWhere((item) => item['version'] == '1.1.0')['sha256'];
      await h.db
          .collection(upstreamArchivesCollection)
          .insertOne({'name': 'mirror', 'version': '1.0.0', 'sha256': digest});

      final reply = await deleteVersion('alpha', '1.1.0', bearer: adminToken);
      expect(reply.status, HttpStatus.ok);
      expect(h.storedArchives(), hasLength(2));
      final event = (await h.auditEvents('version.deleted')).single;
      expect(event['details']['archiveDeleted'], isFalse);
    });

    test('waits for the lock of the object', () async {
      final document = (await h.packageDocument('alpha'))!;
      final digest = (document['versions'] as List)
          .firstWhere((item) => item['version'] == '1.1.0')['sha256'] as String;
      final lock = (await h.metaStore.objectLocks.tryLock(digest))!;
      final deleting = deleteVersion('alpha', '1.1.0', bearer: adminToken);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(h.storedArchives(), hasLength(2));
      await lock.release();
      expect((await deleting).status, HttpStatus.ok);
      expect(h.storedArchives(), hasLength(1));
    });

    test('is refused while the version is being published', () async {
      final claim = await h.metaStore.reserveUpload('alpha', '1.1.0');
      final reply = await deleteVersion('alpha', '1.1.0', bearer: adminToken);
      expect(reply.status, HttpStatus.conflict);
      expect(reply.json['error']['message'], contains('being published'));
      await h.metaStore.releaseUpload('alpha', '1.1.0', claim!);
      expect(versionsOf(await h.packageDocument('alpha')), hasLength(2));
    });

    test('keeps a publish of the version out while it runs', () async {
      final claim = await h.metaStore.reserveUpload('alpha', '2.0.0');
      expect(claim, isNotNull);
      // The reservation a deletion takes is the one a publish needs.
      final error = await h.tryPublish('alpha', '2.0.0', bearer: ownerToken);
      expect(error, contains('2.0.0'));
      await h.metaStore.releaseUpload('alpha', '2.0.0', claim!);
      await h.publish('alpha', '2.0.0', bearer: ownerToken);
    });
  });

  group('deleting a package', () {
    setUp(() async {
      await h.publish('alpha', '1.0.0', bearer: ownerToken);
      await h.publish('alpha', '1.1.0', bearer: ownerToken);
      await h.publish('beta', '1.0.0', bearer: ownerToken);
    });

    test('is for administrators only', () async {
      expect((await deletePackage('alpha')).status, HttpStatus.unauthorized);
      expect((await deletePackage('alpha', bearer: ownerToken)).status,
          HttpStatus.forbidden);
      expect(await h.packageDocument('alpha'), isNotNull);
    });

    test('removes everything of the package and nothing else', () async {
      await h.db.collection(statsCollection).insertMany([
        {'name': 'alpha', 'd20260101': 1},
        {'name': 'beta', 'd20260101': 2},
      ]);
      await h.db.collection(versionStatsCollection).insertMany([
        {'name': 'alpha', 'version': '1.0.0', 'count': 1},
        {'name': 'beta', 'version': '1.0.0', 'count': 2},
      ]);
      await h.db.collection(uploadReservationsCollection).insertOne({
        'name': 'alpha',
        'version': '0.0.1',
        'reservation': 'stale',
        'expiresAt': DateTime.now().subtract(const Duration(minutes: 1)),
      });

      final reply = await deletePackage('alpha', bearer: adminToken);
      expect(reply.status, HttpStatus.ok, reason: reply.body);
      expect(reply.json['success']['message'], 'package deleted');

      expect(await h.packageDocument('alpha'), isNull);
      expect(await h.packageDocument('beta'), isNotNull);
      for (final collection in [statsCollection, versionStatsCollection]) {
        final left = await h.db.collection(collection).find().toList();
        expect([for (final item in left) item['name']], ['beta']);
      }
      expect(
          await h.db
              .collection(uploadReservationsCollection)
              .findOne(where.eq('name', 'alpha')),
          isNull);
      expect(h.storedArchives().single, contains('beta-1.0.0-'));

      final event = (await h.auditEvents('package.deleted')).single;
      expect(event['package'], 'alpha');
      expect(event['details']['versions'], ['1.0.0', '1.1.0']);
      expect(event['details']['archivesDeleted'], 2);

      expect((await h.send('GET', '/api/packages/alpha')).status,
          HttpStatus.found);
      // The name is free again.
      await h.publish('alpha', '0.1.0', bearer: ownerToken);
    });

    test('is refused while a version is being published', () async {
      final claim = await h.metaStore.reserveUpload('alpha', '1.0.0');
      final reply = await deletePackage('alpha', bearer: adminToken);
      expect(reply.status, HttpStatus.conflict);
      await h.metaStore.releaseUpload('alpha', '1.0.0', claim!);
      expect(await h.packageDocument('alpha'), isNotNull);
      expect(h.storedArchives(), hasLength(3));
    });

    test('takes a version published meanwhile with it', () async {
      // A publish adds a version after the deletion read the package.
      final racing = _RacingStore(h.db, onDelete: () async {
        await h.publish('alpha', '2.0.0', bearer: ownerToken);
      });
      final app = h.buildApp(meta: racing);
      final reply = await h.send('DELETE', '/api/packages/alpha',
          bearer: adminToken, using: app);
      expect(reply.status, HttpStatus.ok, reason: reply.body);
      expect(racing.attempts, 2);
      expect(await h.packageDocument('alpha'), isNull);
      // No archive of alpha is left behind, the racing one included.
      expect(h.storedArchives().single, contains('beta-1.0.0-'));
      final event = (await h.auditEvents('package.deleted')).single;
      expect(event['details']['versions'], ['1.0.0', '1.1.0', '2.0.0']);
    });

    test('of a mirrored package is refused', () async {
      await h.db
          .collection(packageCollection)
          .updateOne(where.eq('name', 'beta'), modify.set('private', false));
      final reply = await deletePackage('beta', bearer: adminToken);
      expect(reply.status, HttpStatus.conflict);
      expect(await h.packageDocument('beta'), isNotNull);
      expect((await deleteVersion('beta', '1.0.0', bearer: adminToken)).status,
          HttpStatus.conflict);
    });

    test('of an unknown package is a 404', () async {
      expect((await deletePackage('gamma', bearer: adminToken)).status,
          HttpStatus.notFound);
    });
  });

  group('transferring ownership', () {
    setUp(() async {
      await h.publish('alpha', '1.0.0', bearer: ownerToken);
      await h.db.collection(packageCollection).updateOne(
          where.eq('name', 'alpha'), modify.push('uploaders', 'second@b.c'));
      await h.user('new@b.c', Role.publisher);
    });

    Future<Reply> transfer(Object body, {String? bearer}) =>
        h.send('PUT', '/api/packages/alpha/owner', bearer: bearer, json: body);

    test('replaces the uploaders with one user', () async {
      final reply = await transfer({'email': 'New@B.c'}, bearer: adminToken);
      expect(reply.status, HttpStatus.ok, reason: reply.body);
      expect((await h.packageDocument('alpha'))!['uploaders'], ['new@b.c']);
      final event = (await h.auditEvents('uploader.transferred')).single;
      expect(event['target'], 'new@b.c');
      expect(event['details']['from'], ['owner@b.c', 'second@b.c']);
    });

    test('is for administrators only', () async {
      expect((await transfer({'email': 'new@b.c'})).status,
          HttpStatus.unauthorized);
      expect((await transfer({'email': 'new@b.c'}, bearer: ownerToken)).status,
          HttpStatus.forbidden);
    });

    test('needs an existing user and a valid body', () async {
      expect(
          (await transfer({'email': 'nobody@b.c'}, bearer: adminToken)).status,
          HttpStatus.notFound);
      expect((await transfer({'email': 'x'}, bearer: adminToken)).status,
          HttpStatus.badRequest);
      expect((await transfer({'mail': 'new@b.c'}, bearer: adminToken)).status,
          HttpStatus.badRequest);
      expect((await h.packageDocument('alpha'))!['uploaders'],
          ['owner@b.c', 'second@b.c']);
    });
  });

  group('the admin pages', () {
    late Browser browser;

    setUp(() async {
      await h.publish('alpha', '1.0.0', bearer: ownerToken);
      await h.publish('alpha', '1.1.0', bearer: ownerToken);
      await h.user('new@b.c', Role.publisher);
      browser = await h.logIn('admin@b.c');
    });

    test('delete a version after asking', () async {
      final package = await h.page('/admin/packages/alpha', as: browser);
      expect(package.body,
          contains('href="/admin/packages/alpha/versions/1.1.0/delete"'));
      final confirm = await h
          .page('/admin/packages/alpha/versions/1.1.0/delete', as: browser);
      expect(confirm.status, HttpStatus.ok);
      expect(confirm.body, contains('Delete alpha 1.1.0?'));

      final noToken = await h.post(
          '/admin/packages/alpha/versions/1.1.0/delete',
          as: browser,
          csrf: false);
      expect(noToken.status, HttpStatus.forbidden);
      expect(versionsOf(await h.packageDocument('alpha')), hasLength(2));

      final done = await h.post('/admin/packages/alpha/versions/1.1.0/delete',
          as: browser);
      expect(done.status, HttpStatus.seeOther);
      expect(done.location, '/admin/packages/alpha?done=version-deleted');
      expect(versionsOf(await h.packageDocument('alpha')), ['1.0.0']);

      final last = await h.post('/admin/packages/alpha/versions/1.0.0/delete',
          as: browser);
      expect(last.status, HttpStatus.conflict);
      expect(last.body, contains('only version'));
      // The last version has no delete link.
      expect(last.body, isNot(contains('/versions/1.0.0/delete"')));
    });

    test('delete a package when its name is typed', () async {
      final wrong = await h.post('/admin/packages/alpha/delete',
          as: browser, form: {'confirm_name': 'alph'});
      expect(wrong.status, HttpStatus.badRequest);
      expect(wrong.body, contains('Type the name alpha'));
      expect(await h.packageDocument('alpha'), isNotNull);

      final noToken = await h.post('/admin/packages/alpha/delete',
          as: browser, csrf: false, form: {'confirm_name': 'alpha'});
      expect(noToken.status, HttpStatus.forbidden);

      final done = await h.post('/admin/packages/alpha/delete',
          as: browser, form: {'confirm_name': 'alpha'});
      expect(done.status, HttpStatus.seeOther);
      expect(done.location, '/admin/packages?done=package-deleted');
      expect(await h.packageDocument('alpha'), isNull);
      final list = await h.page(done.location!, as: browser);
      expect(list.body, contains('The package was deleted.'));
    });

    test('transfer the ownership after asking', () async {
      final package = await h.page('/admin/packages/alpha', as: browser);
      expect(package.body,
          contains('<form method="get" action="/admin/packages/alpha/owner"'));
      final confirm = await h.page(
          '/admin/packages/alpha/owner?email=${Uri.encodeQueryComponent('New@b.c')}',
          as: browser);
      expect(confirm.status, HttpStatus.ok);
      expect(
          confirm.body, contains('Make new@b.c the only uploader of alpha?'));
      expect(confirm.body, contains('This removes owner@b.c.'));
      expect(confirm.body, contains('name="confirm" value="yes"'));
      expect(confirm.body, contains('name="email" value="new@b.c"'));
      final invalid =
          await h.page('/admin/packages/alpha/owner?email=nope', as: browser);
      expect(invalid.status, HttpStatus.badRequest);

      // A post without the confirmation, as from the old form, changes
      // nothing.
      final unconfirmed = await h.post('/admin/packages/alpha/owner',
          as: browser, form: {'email': 'new@b.c'});
      expect(unconfirmed.status, HttpStatus.badRequest);
      expect(unconfirmed.body, contains('confirmation page'));
      expect((await h.packageDocument('alpha'))!['uploaders'], ['owner@b.c']);
      expect(await h.auditEvents('uploader.transferred'), isEmpty);

      final done = await h.post('/admin/packages/alpha/owner',
          as: browser, form: {'email': 'new@b.c', 'confirm': 'yes'});
      expect(done.status, HttpStatus.seeOther);
      expect((await h.packageDocument('alpha'))!['uploaders'], ['new@b.c']);
      final unknown = await h.post('/admin/packages/alpha/owner',
          as: browser, form: {'email': 'ghost@b.c', 'confirm': 'yes'});
      expect(unknown.status, HttpStatus.notFound);
      expect(unknown.body, contains('no user with the email ghost@b.c'));
    });

    test('refuse everyone but administrators', () async {
      final publisher = await h.logIn('owner@b.c');
      for (final (method, path, form) in [
        ('GET', '/admin/packages/alpha/versions/1.1.0/delete', null),
        ('POST', '/admin/packages/alpha/versions/1.1.0/delete', null),
        ('POST', '/admin/packages/alpha/delete', {'confirm_name': 'alpha'}),
        ('GET', '/admin/packages/alpha/owner?email=new@b.c', null),
        (
          'POST',
          '/admin/packages/alpha/owner',
          {'email': 'new@b.c', 'confirm': 'yes'}
        ),
      ]) {
        final reply = method == 'GET'
            ? await h.page(path, as: publisher)
            : await h.post(path,
                as: publisher, form: form ?? const <String, Object>{});
        expect(reply.status, HttpStatus.forbidden, reason: '$method $path');
      }
      expect(versionsOf(await h.packageDocument('alpha')), hasLength(2));
      expect((await h.packageDocument('alpha'))!['uploaders'], ['owner@b.c']);
    });
  });

  group('cleanup after a deletion', () {
    late App failing;
    late WebhookStore hooks;

    setUp(() async {
      hooks = WebhookStore(h.db);
      await hooks.ensureIndexes();
      await hooks.insert(
          url: Uri.parse('https://hooks.example/x'),
          events: webhookEvents,
          description: '',
          secret: 's');
      failing = h.buildApp(
          meta: _FailingCleanupStore(h.db), webhooks: WebhookService(hooks));
      await h.publish('alpha', '1.0.0', bearer: ownerToken, using: failing);
      await h.publish('alpha', '1.1.0', bearer: ownerToken, using: failing);
    });

    Future<List<String>> queued() async => [
          for (final item in await h.db
              .collection(webhookDeliveryCollection)
              .find()
              .toList())
            item['event'] as String,
        ];

    test('that fails still deletes, audits and notifies a version', () async {
      final reply = await h.send('DELETE', '/api/packages/alpha/versions/1.1.0',
          bearer: adminToken, using: failing);
      expect(reply.status, HttpStatus.ok, reason: reply.body);
      expect(versionsOf(await h.packageDocument('alpha')), ['1.0.0']);
      final event = (await h.auditEvents('version.deleted')).single;
      expect(event['details']['cleanupError'], contains('stats are down'));
      expect(event['details']['archiveDeleted'], isTrue);
      expect(await queued(), contains('version.deleted'));
      // A retry finds nothing left to delete.
      expect(
          (await h.send('DELETE', '/api/packages/alpha/versions/1.1.0',
                  bearer: adminToken, using: failing))
              .status,
          HttpStatus.notFound);
    });

    test('that fails still deletes, audits and notifies a package', () async {
      final reply = await h.send('DELETE', '/api/packages/alpha',
          bearer: adminToken, using: failing);
      expect(reply.status, HttpStatus.ok, reason: reply.body);
      expect(await h.packageDocument('alpha'), isNull);
      final event = (await h.auditEvents('package.deleted')).single;
      expect(event['details']['cleanupError'], contains('stats are down'));
      expect(event['details']['archivesDeleted'], 2);
      expect(h.storedArchives(), isEmpty);
      expect(await queued(), contains('package.deleted'));
    });

    test('through the admin page also succeeds', () async {
      final browser = await h.logIn('admin@b.c', using: failing);
      final reply = await h.post('/admin/packages/alpha/versions/1.1.0/delete',
          as: browser, using: failing);
      expect(reply.status, HttpStatus.seeOther, reason: reply.body);
      expect(versionsOf(await h.packageDocument('alpha')), ['1.0.0']);
      expect((await h.auditEvents('version.deleted')).single['details'],
          contains('cleanupError'));
    });
  });
}

/// A store whose cleanup after a deletion always fails.
class _FailingCleanupStore extends MongoStore {
  _FailingCleanupStore(super.db);

  @override
  Future<void> removeVersionData(String name, String version) async =>
      throw StateError('stats are down');

  @override
  Future<void> removePackageData(String name) async =>
      throw StateError('stats are down');
}

/// A store that runs [onDelete] once, right before the first attempt to
/// delete a package document, and counts the attempts.
class _RacingStore extends MongoStore {
  final Future<void> Function() onDelete;
  int attempts = 0;

  _RacingStore(super.db, {required this.onDelete});

  @override
  Future<bool> deletePackage(String name, Set<String> versions) async {
    if (attempts++ == 0) await onDelete();
    return super.deletePackage(name, versions);
  }
}
