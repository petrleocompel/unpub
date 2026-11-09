import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:mongo_dart/mongo_dart.dart';

import '../auth/account_service.dart';
import '../auth/accounts.dart';
import '../config/config.dart';
import '../migrate/migrations.dart';
import '../redact.dart';
import '../store/account_store.dart';
import '../store/audit_store.dart';

const _connectTimeout = Duration(seconds: 30);

const _roleNames = ['admin', 'publisher', 'reader'];

/// A command that works on the database named by `--config`.
abstract class _DatabaseCommand extends Command<int> {
  @override
  bool get takesArguments => false;

  /// Whether the command only reads, so must not create indexes.
  bool get readOnly => false;

  _DatabaseCommand() {
    argParser.addOption('config',
        abbr: 'c',
        valueHelp: 'path',
        help: 'YAML config file. Defaults to ${Config.defaultPath} '
            'when it exists.');
  }

  Future<int> runWith(Config config, Db db, AccountService accounts);

  @override
  Future<int> run() async {
    final Config config;
    try {
      config = Config.load(path: argResults!.option('config'));
    } on ConfigException catch (error) {
      stderr.writeln(error);
      return 1;
    }

    Db? db;
    try {
      final connection = db = await Db.create(config.mongo.uri);
      await connection.open().timeout(_connectTimeout);
      final store = AccountStore(connection);
      final audit = MongoAuditStore(connection);
      if (!readOnly) {
        await store.ensureIndexes();
        await audit.ensureIndexes();
        await store.reconcileAdminSet(DateTime.now());
      }
      return await runWith(
          config, connection, AccountService(store, audit: audit));
    } on AccountException catch (error) {
      stderr.writeln(error.message);
      return 1;
    } on UsageException {
      rethrow;
    } catch (error) {
      stderr.writeln(redactConnectionStrings('$error'));
      return 1;
    } finally {
      await db?.close().catchError((Object _) {});
    }
  }

  String _option(String name) => argResults!.option(name)!;

  Role _role() => Role.tryParse(_option('role'))!;

  /// The first line of standard input, which holds a password.
  static Future<String> readSecretLine() async {
    final line = await stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .firstWhere((_) => true, orElse: () => '');
    if (line.isEmpty) {
      throw const AccountException.invalid('no password on standard input');
    }
    return line;
  }
}

/// Runs the pending data migrations.
class MigrateCommand extends _DatabaseCommand {
  @override
  String get name => 'migrate';

  @override
  String get description => 'Apply pending data migrations.';

  MigrateCommand() {
    argParser.addFlag('dry-run',
        negatable: false, help: 'List what would change and write nothing.');
  }

  bool get _dryRun => argResults!.flag('dry-run');

  @override
  bool get readOnly => _dryRun;

  @override
  Future<int> runWith(Config config, Db db, AccountService accounts) async {
    final outcomes =
        await Migrator(db, accounts, config.auth).run(dryRun: _dryRun);
    for (final outcome in outcomes) {
      final status = switch (outcome.status) {
        MigrationStatus.applied => 'applied',
        MigrationStatus.alreadyApplied => 'already applied',
        MigrationStatus.wouldApply => 'would apply',
      };
      stdout.writeln('${outcome.id}: $status');
      for (final change in outcome.changes) {
        stdout.writeln('  $change');
      }
    }
    final changed = outcomes.fold<int>(0, (n, o) => n + o.changes.length);
    stdout.writeln(_dryRun
        ? 'Dry run: $changed change(s) planned, nothing written.'
        : '$changed change(s) made in '
            '${outcomes.where((o) => o.status == MigrationStatus.applied).length}'
            ' step(s).');
    return 0;
  }
}

/// Parent of the `unpub admin` commands.
class AdminCommand extends Command<int> {
  @override
  String get name => 'admin';

  @override
  String get description => 'Administer users and tokens.';

  AdminCommand() {
    addSubcommand(_CreateUserCommand());
    addSubcommand(_SetPasswordCommand());
    addSubcommand(_SetRoleCommand());
    addSubcommand(_SetDisabledCommand('disable', true));
    addSubcommand(_SetDisabledCommand('enable', false));
    addSubcommand(_ListUsersCommand());
    addSubcommand(_CreateTokenCommand());
  }
}

class _CreateUserCommand extends _DatabaseCommand {
  @override
  String get name => 'create-user';

  @override
  String get description =>
      'Create a user. Without a password it cannot log in yet.';

  _CreateUserCommand() {
    argParser
      ..addOption('email', mandatory: true, valueHelp: 'address')
      ..addOption('role', mandatory: true, allowed: _roleNames)
      ..addOption('display-name', valueHelp: 'name')
      ..addOption('password',
          valueHelp: 'secret',
          help: 'Visible in the process list. Prefer --password-stdin.')
      ..addFlag('password-stdin',
          negatable: false, help: 'Read the password from standard input.');
  }

  @override
  Future<int> runWith(Config config, Db db, AccountService accounts) async {
    final args = argResults!;
    final fromStdin = args.flag('password-stdin');
    if (fromStdin && args.option('password') != null) {
      usageException('Use only one of --password and --password-stdin.');
    }
    final user = await accounts.createUser(
      email: _option('email'),
      role: _role(),
      displayName: args.option('display-name'),
      password: fromStdin
          ? await _DatabaseCommand.readSecretLine()
          : args.option('password'),
    );
    stdout.writeln('created ${user.email} with role ${user.role.name}');
    return 0;
  }
}

class _SetPasswordCommand extends _DatabaseCommand {
  @override
  String get name => 'set-password';

  @override
  String get description => 'Set the password of a user.';

  _SetPasswordCommand() {
    argParser
      ..addOption('email', mandatory: true, valueHelp: 'address')
      ..addFlag('password-stdin',
          negatable: false, help: 'Read the password from standard input.');
  }

  Future<String> _prompt() async {
    if (!stdin.hasTerminal) {
      usageException('Without a terminal, use --password-stdin.');
    }
    stdout.write('New password: ');
    stdin.echoMode = false;
    try {
      final password = stdin.readLineSync() ?? '';
      stdout.writeln();
      return password;
    } finally {
      stdin.echoMode = true;
    }
  }

  @override
  Future<int> runWith(Config config, Db db, AccountService accounts) async {
    final user = await accounts.requireUserByEmail(_option('email'));
    final password = argResults!.flag('password-stdin')
        ? await _DatabaseCommand.readSecretLine()
        : await _prompt();
    await accounts.setPassword(user, password);
    stdout.writeln('password set for ${user.email}');
    return 0;
  }
}

class _SetRoleCommand extends _DatabaseCommand {
  @override
  String get name => 'set-role';

  @override
  String get description => 'Change the role of a user.';

  _SetRoleCommand() {
    argParser
      ..addOption('email', mandatory: true, valueHelp: 'address')
      ..addOption('role', mandatory: true, allowed: _roleNames);
  }

  @override
  Future<int> runWith(Config config, Db db, AccountService accounts) async {
    final user = await accounts.requireUserByEmail(_option('email'));
    final updated = await accounts.updateUser(user, role: _role());
    stdout.writeln('${updated.email} now has role ${updated.role.name}');
    return 0;
  }
}

class _SetDisabledCommand extends _DatabaseCommand {
  @override
  final String name;
  final bool disabled;

  @override
  String get description =>
      disabled ? 'Prevent a user from signing in.' : 'Re-enable a user.';

  _SetDisabledCommand(this.name, this.disabled) {
    argParser.addOption('email', mandatory: true, valueHelp: 'address');
  }

  @override
  Future<int> runWith(Config config, Db db, AccountService accounts) async {
    final user = await accounts.requireUserByEmail(_option('email'));
    await accounts.updateUser(user, disabled: disabled);
    stdout.writeln('${user.email} ${disabled ? 'disabled' : 'enabled'}');
    return 0;
  }
}

class _ListUsersCommand extends _DatabaseCommand {
  @override
  String get name => 'list-users';

  @override
  String get description => 'List all users.';

  @override
  bool get readOnly => true;

  @override
  Future<int> runWith(Config config, Db db, AccountService accounts) async {
    stdout.writeln('EMAIL\tROLE\tSTATUS\tPASSWORD\tNAME');
    for (final user in await accounts.store.listUsers()) {
      stdout.writeln([
        user.email,
        user.role.name,
        user.disabled ? 'disabled' : 'enabled',
        user.passwordHash == null ? 'none' : 'set',
        user.displayName,
      ].join('\t'));
    }
    return 0;
  }
}

class _CreateTokenCommand extends _DatabaseCommand {
  @override
  String get name => 'create-token';

  @override
  String get description =>
      'Create an API token and print its secret, which is shown only once.';

  _CreateTokenCommand() {
    argParser
      ..addOption('email', mandatory: true, valueHelp: 'address')
      ..addOption('name', mandatory: true, valueHelp: 'label')
      ..addMultiOption('scopes',
          allowed: const ['read', 'publish'],
          help: 'Defaults to everything the role of the user allows.')
      ..addOption('expires-in',
          valueHelp: 'duration', help: 'For example 12h, 30d or 8w.');
  }

  @override
  Future<int> runWith(Config config, Db db, AccountService accounts) async {
    final args = argResults!;
    DateTime? expiresAt;
    final expiresIn = args.option('expires-in');
    if (expiresIn != null) {
      final duration = parseDuration(expiresIn);
      if (duration == null) {
        usageException('--expires-in must look like 12h, 30d or 8w.');
      }
      expiresAt = accounts.clock().add(duration);
    }
    final names = args.multiOption('scopes');
    final user = await accounts.requireUserByEmail(_option('email'));
    final created = await accounts.createToken(
      user,
      name: _option('name'),
      scopes: names.isEmpty ? null : names.map(Scope.tryParse).nonNulls.toSet(),
      expiresAt: expiresAt,
    );
    stdout.writeln(created.secret);
    return 0;
  }
}
