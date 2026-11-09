import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:logging/logging.dart';

import '../config/config.dart';
import '../logging.dart';
import '../server.dart';
import '../version.dart';

/// Exit code for a reserved command that does not exist yet.
const exitNotImplemented = 2;

/// Exit code for wrong usage, following sysexits.h.
const exitUsage = 64;

final _log = Logger('unpub.cli');

/// Runs the command line interface and returns the process exit code.
Future<int> runCli(List<String> args) async {
  final runner = CommandRunner<int>(
    'unpub',
    'Self-hosted private Dart Pub server.',
  )
    ..addCommand(_ServeCommand())
    ..addCommand(_VersionCommand())
    ..addCommand(_ReservedCommand('migrate', 'Migrate stored data.'))
    ..addCommand(_ReservedCommand('admin', 'Administer users and tokens.'));

  try {
    return await runner.run(args) ?? 0;
  } on UsageException catch (error) {
    stderr.writeln(error);
    return exitUsage;
  }
}

class _ServeCommand extends Command<int> {
  @override
  String get name => 'serve';

  @override
  String get description => 'Start the server.';

  @override
  bool get takesArguments => false;

  _ServeCommand() {
    argParser
      ..addOption('config',
          abbr: 'c',
          valueHelp: 'path',
          help: 'YAML config file. Defaults to ${Config.defaultPath} '
              'when it exists.')
      ..addOption('host', valueHelp: 'address', help: 'Overrides server.host.')
      ..addOption('port',
          abbr: 'p', valueHelp: 'number', help: 'Overrides server.port.');
  }

  @override
  Future<int> run() async {
    final args = argResults!;
    final Config config;
    try {
      config = Config.load(
        path: args.option('config'),
        host: args.option('host'),
        port: args.option('port'),
      );
    } on ConfigException catch (error) {
      stderr.writeln(error);
      return 1;
    }

    final logging = setupLogging(
      level: config.logging.level,
      format: config.logging.format,
    );
    try {
      return await _serve(config);
    } finally {
      await logging.cancel();
      await stdout.flush();
    }
  }

  Future<int> _serve(Config config) async {
    final UnpubServer server;
    try {
      server = await UnpubServer.start(config);
    } catch (error, stackTrace) {
      _log.severe('failed to start', error, stackTrace);
      return 1;
    }
    _log.info(LogEvent('listening', {
      'host': config.server.host,
      'port': server.port,
      'readAccess': config.auth.readAccess.name,
    }));
    if (config.auth.bootstrapToken == null) {
      _log.warning('auth.bootstrapToken is not set, publishing is disabled');
    }
    await server.waitForShutdown();
    return 0;
  }
}

class _VersionCommand extends Command<int> {
  @override
  String get name => 'version';

  @override
  String get description => 'Print the unpub version.';

  @override
  bool get takesArguments => false;

  @override
  int run() {
    stdout.writeln('unpub $packageVersion');
    return 0;
  }
}

/// Holds the name of a command that a later phase implements.
class _ReservedCommand extends Command<int> {
  @override
  final String name;

  @override
  final String description;

  _ReservedCommand(this.name, String description)
      : description = '$description Not implemented yet.';

  @override
  int run() {
    stderr.writeln('not implemented yet, see docs/ROADMAP.md');
    return exitNotImplemented;
  }
}
