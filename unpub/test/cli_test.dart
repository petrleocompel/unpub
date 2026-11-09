import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
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

  for (var name in ['migrate', 'admin']) {
    test('$name is reserved', () async {
      var result = await unpub([name]);
      expect(result.exitCode, 2);
      expect(
          result.stderr, contains('not implemented yet, see docs/ROADMAP.md'));
    });
  }

  test('an unknown command is a usage error', () async {
    var result = await unpub(['nope']);
    expect(result.exitCode, 64);
    expect(result.stderr, contains('Could not find a command'));
  });

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
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
