import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:http/http.dart' as http;
import 'package:mongo_dart/mongo_dart.dart' show Db, ObjectId, where;
import 'package:path/path.dart' as path;
import 'package:test/test.dart';
import 'package:unpub/unpub.dart';
import 'package:yaml/yaml.dart';

import 'utils.dart' show testMongoUri;

Future<ProcessResult> unpub(List<String> args) => Process.run(
    Platform.resolvedExecutable, ['run', 'bin/unpub.dart', ...args]);

void main() {
  test('version matches the pubspec', () async {
    var pubspec = loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
    expect(packageVersion, pubspec['version']);

    var result = await unpub(['version']);
    expect(result.exitCode, 0);
    expect(result.stdout, contains('unpub $packageVersion'));
  });

  for (var args in [
    <String>[],
    ['--help']
  ]) {
    test('unpub ${args.join(' ')} prints help', () async {
      var result = await unpub(args);
      expect(result.exitCode, 0);
      expect(result.stdout, contains('Available commands:'));
      expect(result.stdout, allOf(contains('serve'), contains('version')));
      expect(result.stdout, allOf(contains('migrate'), contains('admin')));
    });
  }

  test('an unknown command is a usage error', () async {
    var result = await unpub(['nope']);
    expect(result.exitCode, 64);
    expect(result.stderr, contains('Could not find a command'));
  });

  group('admin and migrate', () {
    late Directory directory;
    late String configPath;
    late Db db;

    Future<ProcessResult> run(List<String> args) =>
        unpub([args.first, ...args.skip(1), '--config', configPath]);

    Future<ProcessResult> admin(List<String> args) =>
        unpub(['admin', args.first, ...args.skip(1), '--config', configPath]);

    Future<ProcessResult> adminWithStdin(
        List<String> args, String input) async {
      final process = await Process.start(Platform.resolvedExecutable, [
        'run',
        'bin/unpub.dart',
        'admin',
        ...args,
        '--config',
        configPath,
      ]);
      final out = process.stdout.transform(utf8.decoder).join();
      final err = process.stderr.transform(utf8.decoder).join();
      process.stdin.writeln(input);
      await process.stdin.close();
      final code = await process.exitCode;
      return ProcessResult(process.pid, code, await out, await err);
    }

    Future<void> clean() async {
      for (final name in [
        'users',
        'tokens',
        'sessions',
        'audit',
        'migrations',
        'packages',
        'admin_set',
      ]) {
        await db.dropCollection(name);
      }
    }

    Future<Map<String, dynamic>?> findUser(String email) =>
        db.collection('users').findOne(where.eq('email', email));

    setUpAll(() async {
      db = Db(testMongoUri);
      await db.open();
    });

    tearDownAll(() => db.close());

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('unpub-cli-admin-');
      configPath = path.join(directory.path, 'unpub.yaml');
      File(configPath).writeAsStringSync('mongo:\n  uri: $testMongoUri\n'
          'auth:\n  bootstrapEmail: ops@example.com\n');
      await clean();
    });

    tearDown(() async {
      await directory.delete(recursive: true);
      await clean();
    });

    test('create-user with --password makes a user that can log in', () async {
      var result = await admin([
        'create-user',
        '--email',
        'Root@Example.com',
        '--role',
        'admin',
        '--display-name',
        'The Root',
        '--password',
        'long-enough-password',
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, contains('root@example.com'));
      expect('${result.stdout}${result.stderr}',
          isNot(contains('long-enough-password')));

      var user = (await findUser('root@example.com'))!;
      expect(user['role'], 'admin');
      expect(user['displayName'], 'The Root');
      expect(user['disabled'], false);
      expect(user['passwordHash'], startsWith(r'$argon2id$'));
      expect(user['createdAt'], isA<DateTime>());
      expect(user['updatedAt'], isA<DateTime>());
      expect(user['lastLoginAt'], isNull);

      expect(
          await const PasswordHasher()
              .verify('long-enough-password', user['passwordHash'] as String),
          isTrue);
    });

    test('create-user without a password makes a placeholder', () async {
      var result =
          await admin(['create-user', '--email', 'a@b.c', '--role', 'reader']);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      var user = (await findUser('a@b.c'))!;
      expect(user['passwordHash'], isNull);
      expect(user['displayName'], 'a');
    });

    test('create-user --password-stdin reads the password', () async {
      var result = await adminWithStdin(
        [
          'create-user',
          '--email',
          'a@b.c',
          '--role',
          'publisher',
          '--password-stdin'
        ],
        'from-standard-input',
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      var user = (await findUser('a@b.c'))!;
      expect(
          await const PasswordHasher()
              .verify('from-standard-input', user['passwordHash'] as String),
          isTrue);
    });

    test('create-user reports a duplicate and an invalid role', () async {
      await admin(['create-user', '--email', 'a@b.c', '--role', 'reader']);
      var duplicate =
          await admin(['create-user', '--email', 'A@B.C', '--role', 'reader']);
      expect(duplicate.exitCode, 1);
      expect(duplicate.stderr, contains('already exists'));

      var badRole =
          await admin(['create-user', '--email', 'd@e.f', '--role', 'owner']);
      expect(badRole.exitCode, 64);
    });

    test('--password and --password-stdin conflict', () async {
      var result = await admin([
        'create-user',
        '--email',
        'a@b.c',
        '--role',
        'reader',
        '--password',
        'long-enough',
        '--password-stdin'
      ]);
      expect(result.exitCode, 64);
      expect(await findUser('a@b.c'), isNull);
    });

    test('set-password replaces the password', () async {
      await admin(['create-user', '--email', 'a@b.c', '--role', 'reader']);
      var result = await adminWithStdin(
          ['set-password', '--email', 'a@b.c', '--password-stdin'],
          'brand-new-password');
      expect(result.exitCode, 0, reason: '${result.stderr}');
      var user = (await findUser('a@b.c'))!;
      expect(
          await const PasswordHasher()
              .verify('brand-new-password', user['passwordHash'] as String),
          isTrue);
    });

    test('set-password without a terminal asks for --password-stdin', () async {
      await admin(['create-user', '--email', 'a@b.c', '--role', 'reader']);
      var result = await admin(['set-password', '--email', 'a@b.c']);
      expect(result.exitCode, 64);
      expect(result.stderr, contains('--password-stdin'));
    });

    test('set-password rejects a short password', () async {
      await admin(['create-user', '--email', 'a@b.c', '--role', 'reader']);
      var result = await adminWithStdin(
          ['set-password', '--email', 'a@b.c', '--password-stdin'], 'short');
      expect(result.exitCode, 1);
      expect(result.stderr, contains('at least 8'));
    });

    test('set-role, disable, enable and list-users', () async {
      await admin(['create-user', '--email', 'admin@b.c', '--role', 'admin']);
      await admin(['create-user', '--email', 'a@b.c', '--role', 'reader']);

      var result =
          await admin(['set-role', '--email', 'a@b.c', '--role', 'publisher']);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect((await findUser('a@b.c'))!['role'], 'publisher');

      result = await admin(['disable', '--email', 'a@b.c']);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect((await findUser('a@b.c'))!['disabled'], true);

      var listed = await admin(['list-users']);
      expect(listed.exitCode, 0, reason: '${listed.stderr}');
      expect(listed.stdout, contains('a@b.c\tpublisher\tdisabled\tnone'));
      expect(listed.stdout, contains('admin@b.c\tadmin\tenabled'));

      result = await admin(['enable', '--email', 'a@b.c']);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect((await findUser('a@b.c'))!['disabled'], false);
    });

    test('the last administrator cannot be removed', () async {
      await admin(['create-user', '--email', 'admin@b.c', '--role', 'admin']);
      var result = await admin(['disable', '--email', 'admin@b.c']);
      expect(result.exitCode, 1);
      expect(result.stderr, contains('last enabled administrator'));
    });

    test('a command rebuilds the admin set before it runs', () async {
      await admin(['create-user', '--email', 'admin@b.c', '--role', 'admin']);
      await admin(['create-user', '--email', 'a@b.c', '--role', 'reader']);
      await db
          .collection('admin_set')
          .deleteMany(where.eq('_id', 'enabled_admins'));

      final result =
          await admin(['set-role', '--email', 'a@b.c', '--role', 'publisher']);

      expect(result.exitCode, 0, reason: '${result.stderr}');
      final set = await db
          .collection('admin_set')
          .findOne(where.eq('_id', 'enabled_admins'));
      expect(set!['userIds'],
          [((await findUser('admin@b.c'))!['_id'] as ObjectId).oid]);
    });

    test('an unknown user is reported', () async {
      var result = await admin(['disable', '--email', 'nobody@b.c']);
      expect(result.exitCode, 1);
      expect(result.stderr, contains('nobody@b.c'));
    });

    test('create-token prints the secret once and stores only its hash',
        () async {
      await admin(['create-user', '--email', 'a@b.c', '--role', 'publisher']);
      var result = await admin([
        'create-token',
        '--email',
        'a@b.c',
        '--name',
        'ci',
        '--scopes',
        'read,publish',
        '--expires-in',
        '30d'
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final secret = (result.stdout as String).trim();
      expect(secret.length, greaterThanOrEqualTo(43));

      final token = (await db.collection('tokens').findOne())!;
      expect(token['hash'], hashSecret(secret));
      expect(token['prefix'], secret.substring(0, 8));
      expect(token['scopes'], unorderedEquals(['read', 'publish']));
      expect(token.values, isNot(contains(secret)));
      final expiresAt = token['expiresAt'] as DateTime;
      expect(expiresAt.difference(DateTime.now()).inDays, closeTo(30, 1));
    });

    test('create-token defaults to the scopes of the role', () async {
      await admin(['create-user', '--email', 'a@b.c', '--role', 'reader']);
      var result =
          await admin(['create-token', '--email', 'a@b.c', '--name', 'laptop']);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect((await db.collection('tokens').findOne())!['scopes'], ['read']);
    });

    test('a reader cannot get a publish token', () async {
      await admin(['create-user', '--email', 'a@b.c', '--role', 'reader']);
      var result = await admin([
        'create-token',
        '--email',
        'a@b.c',
        '--name',
        'x',
        '--scopes',
        'publish'
      ]);
      expect(result.exitCode, 1);
      expect(await db.collection('tokens').findOne(), isNull);
    });

    test('create-token rejects a bad duration', () async {
      await admin(['create-user', '--email', 'a@b.c', '--role', 'reader']);
      var result = await admin([
        'create-token',
        '--email',
        'a@b.c',
        '--name',
        'x',
        '--expires-in',
        'soon'
      ]);
      expect(result.exitCode, 64);
      expect(
          result.stderr,
          contains(
              '--expires-in must look like 12h, 30d, 8w or 1y, or be never.'));
    });

    test('create-token takes years and never', () async {
      await admin(['create-user', '--email', 'a@b.c', '--role', 'reader']);
      Future<DateTime?> expiryOf(String expiresIn) async {
        final result = await admin([
          'create-token',
          '--email',
          'a@b.c',
          '--name',
          expiresIn,
          '--expires-in',
          expiresIn
        ]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final token =
            await db.collection('tokens').findOne({'name': expiresIn});
        return token!['expiresAt'] as DateTime?;
      }

      final year = await expiryOf('1y');
      expect(year!.difference(DateTime.now()).inDays, closeTo(365, 1));
      expect(await expiryOf('never'), isNull);
    });

    test('commands record who did what', () async {
      await admin(['create-user', '--email', 'a@b.c', '--role', 'reader']);
      final event = (await db.collection('audit').findOne())!;
      expect(event['actor'], 'system');
      expect(event['action'], 'user.created');
      expect(event['target'], 'a@b.c');
    });

    test('migrate creates users once and dry-run writes nothing', () async {
      await db.collection('packages').insertOne({
        'name': 'p',
        'uploaders': ['dev@b.c', 'OPS@example.com'],
        'versions': [],
      });

      var dry = await run(['migrate', '--dry-run']);
      expect(dry.exitCode, 0, reason: '${dry.stderr}');
      expect(dry.stdout, contains('would apply'));
      expect(dry.stdout, contains('dev@b.c'));
      expect(await findUser('dev@b.c'), isNull);
      expect(await db.collection('migrations').findOne(), isNull);

      var first = await run(['migrate']);
      expect(first.exitCode, 0, reason: '${first.stderr}');
      expect(first.stdout, contains('0001_users_from_uploaders: applied'));
      expect((await findUser('dev@b.c'))!['role'], 'publisher');
      expect((await findUser('ops@example.com'))!['role'], 'admin');

      var second = await run(['migrate']);
      expect(second.exitCode, 0, reason: '${second.stderr}');
      expect(second.stdout, contains('already applied'));
    });

    test('migrate backfills archive hashes from the configured store',
        () async {
      final storage = Directory(path.join(directory.path, 'archives'))
        ..createSync();
      File(configPath).writeAsStringSync('mongo:\n  uri: $testMongoUri\n'
          'storage:\n  file:\n    path: ${storage.path}\n'
          'auth:\n  bootstrapEmail: ops@example.com\n');
      File(path.join(storage.path, 'p-1.0.0.tar.gz')).writeAsBytesSync([1, 2]);
      await db.collection('packages').insertOne({
        'name': 'p',
        'uploaders': <String>[],
        'versions': [
          {'version': '1.0.0'},
          {'version': '2.0.0'},
        ],
      });
      Future<List> versions() async => (await db
          .collection('packages')
          .findOne(where.eq('name', 'p')))!['versions'] as List;

      final dry = await run(['migrate', '--dry-run']);
      expect(dry.exitCode, 0, reason: '${dry.stderr}');
      expect(dry.stdout, contains('hash p@1.0.0'));
      expect(dry.stdout, contains('skip p@2.0.0: archive missing'));
      expect((await versions()).first.containsKey('sha256'), isFalse);

      final real = await run(['migrate']);
      expect(real.exitCode, 0, reason: '${real.stderr}');
      expect(real.stdout, contains('0002_version_sha256: applied'));
      expect((await versions()).first['sha256'],
          sha256.convert([1, 2]).toString());

      final again = await run(['migrate']);
      expect(again.stdout, contains('0002_version_sha256: already applied'));

      File(path.join(storage.path, 'p-2.0.0.tar.gz')).writeAsBytesSync([3]);
      final rerun = await run(['migrate', '--rerun', '0002']);
      expect(rerun.exitCode, 0, reason: '${rerun.stderr}');
      expect(rerun.stdout, contains('0002_version_sha256: applied'));
      expect(rerun.stdout, contains('hash p@2.0.0'));
      expect((await versions()).last['sha256'], sha256.convert([3]).toString());

      final refused = await run(['migrate', '--rerun', '0001']);
      expect(refused.exitCode, 64);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('a bad config is reported', () async {
      var result =
          await unpub(['admin', 'list-users', '--config', '/nonexistent.yaml']);
      expect(result.exitCode, 1);
      expect(result.stderr, contains('config file not found'));
    });

    test('an unreachable database does not print the password', () async {
      File(configPath).writeAsStringSync(
          'mongo:\n  uri: mongodb://user:hunter2@127.0.0.1:1/db\n');
      var result = await admin(['list-users']);
      expect(result.exitCode, 1);
      expect('${result.stdout}${result.stderr}', isNot(contains('hunter2')));
    }, timeout: const Timeout(Duration(minutes: 2)));
  },
      // Every step is a separate `dart run`, which takes several seconds on
      // a CI runner, so the default timeout of 30 seconds is too short.
      timeout: const Timeout(Duration(minutes: 3)));

  group('serve', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('unpub-cli-');
    });

    tearDown(() async {
      await directory.delete(recursive: true);
    });

    test('lists every configuration problem and exits', () async {
      var config = File(path.join(directory.path, 'bad.yaml'))
        ..writeAsStringSync('server:\n  port: x\nlogging:\n  format: xml\n');
      var result = await unpub(['serve', '--config', config.path]);
      expect(result.exitCode, 1);
      expect(result.stderr, contains('Invalid configuration'));
      expect(result.stderr, contains('server.port'));
      expect(result.stderr, contains('logging.format'));
    });

    for (var uri in [
      'mongodb://user:hunter2@localhost:bad/db',
      'mongodb://user:hunter2@127.0.0.1:1/db',
    ]) {
      test('never prints the password of $uri', () async {
        var config = File(path.join(directory.path, 'unpub.yaml'))
          ..writeAsStringSync('mongo:\n  uri: "$uri"\n'
              'server:\n  port: 0\n'
              'storage:\n  file:\n    path: ${directory.path}\n');
        var result = await unpub(['serve', '--config', config.path]);
        expect(result.exitCode, 1, reason: '${result.stdout}${result.stderr}');
        expect('${result.stdout}${result.stderr}', isNot(contains('hunter2')));
      }, timeout: const Timeout(Duration(minutes: 2)));
    }

    test('authenticated read access is wired through the config', () async {
      var config = File(path.join(directory.path, 'unpub.yaml'))
        ..writeAsStringSync('''
server:
  host: 127.0.0.1
mongo:
  uri: $testMongoUri
storage:
  file:
    path: ${path.join(directory.path, 'packages')}
logging:
  format: json
auth:
  readAccess: authenticated
  readTokens:
    - reader-token
''');
      var process = await Process.start(Platform.resolvedExecutable,
          ['run', 'bin/unpub.dart', 'serve', '-c', config.path, '-p', '0']);
      addTearDown(process.kill);
      unawaited(process.stderr.drain<void>());
      // Stays subscribed, as the server exits if its stdout closes.
      var lines = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .asBroadcastStream()
        ..listen((_) {});
      var listening = await lines
          .firstWhere((line) => line.contains('"listening"'))
          .timeout(const Duration(minutes: 1));
      expect(json.decode(listening)['readAccess'], 'authenticated');
      var base = Uri.parse(
          'http://127.0.0.1:${json.decode(listening)['port'] as int}');

      var open = await http.get(base.resolve('/healthz'));
      expect(open.statusCode, HttpStatus.ok);
      var denied = await http.get(base.resolve('/webapi/packages'));
      expect(denied.statusCode, HttpStatus.unauthorized);
      var allowed = await http.get(base.resolve('/webapi/packages'),
          headers: {'authorization': 'Bearer reader-token'});
      expect(allowed.statusCode, HttpStatus.ok);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a missing config file is reported', () async {
      var result = await unpub(['serve', '--config', '/nonexistent.yaml']);
      expect(result.exitCode, 1);
      expect(result.stderr, contains('config file not found'));
    });

    test('serves from a config file and shuts down on SIGTERM', () async {
      var config = File(path.join(directory.path, 'unpub.yaml'))
        ..writeAsStringSync('''
server:
  host: 127.0.0.1
  port: 4000
mongo:
  uri: $testMongoUri
storage:
  file:
    path: ${path.join(directory.path, 'packages')}
logging:
  format: json
''');

      var process = await Process.start(Platform.resolvedExecutable,
          ['run', 'bin/unpub.dart', 'serve', '-c', config.path, '-p', '0']);
      var stderrText = process.stderr.transform(utf8.decoder).join();
      var lines = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .asBroadcastStream();
      var collected = <String>[];
      lines.listen(collected.add);

      var listening = await lines
          .firstWhere((line) => line.contains('"listening"'))
          .timeout(const Duration(minutes: 1));
      var port = json.decode(listening)['port'] as int;

      var healthz = await http.get(Uri.parse('http://127.0.0.1:$port/healthz'));
      expect(healthz.statusCode, HttpStatus.ok);
      var readyz = await http.get(Uri.parse('http://127.0.0.1:$port/readyz'));
      expect(readyz.statusCode, HttpStatus.ok, reason: readyz.body);

      process.kill(ProcessSignal.sigterm);
      var code = await process.exitCode.timeout(const Duration(seconds: 30));
      expect(code, 0, reason: await stderrText);
      expect(collected, contains(contains('"stopped"')));
      expect(collected.where((l) => l.contains('"path":"/healthz"')),
          hasLength(1));
      expect(collected, contains(contains('"created storage directory"')));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
