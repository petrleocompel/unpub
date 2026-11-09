import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:mongo_dart/mongo_dart.dart';

import '../auth/account_service.dart';
import '../auth/accounts.dart';
import '../config/config.dart';
import '../logging.dart';
import '../store/mongo_store.dart';
import '../store/package_store.dart';

final migrationCollection = 'migrations';

final _log = Logger('unpub.migrate');

const _duplicateKeyCode = 11000;

enum MigrationStatus { applied, alreadyApplied, wouldApply }

/// What happened to one migration step.
class MigrationOutcome {
  final String id;
  final MigrationStatus status;

  /// One human readable line per change made or, in a dry run, planned.
  final List<String> changes;

  const MigrationOutcome(this.id, this.status, this.changes);
}

class _Step {
  final String id;
  final Future<List<String>> Function(bool dryRun) apply;

  /// Whether the step can usefully be run again after it was recorded.
  final bool rerunnable;

  const _Step(this.id, this.apply, {this.rerunnable = false});
}

/// Applies each data migration once and records it in `migrations`.
///
/// A step also tolerates being repeated after a crash, because it is recorded
/// only once it has completely finished.
class Migrator {
  final Db db;
  final AccountService accounts;
  final AuthConfig auth;
  final PackageStore packageStore;

  Migrator(this.db, this.accounts, this.auth, this.packageStore);

  late final _steps = [
    _Step('0001_users_from_uploaders', _usersFromUploaders),
    _Step('0002_version_sha256', _versionSha256, rerunnable: true),
  ];

  /// The ids to give [run] as `rerun`, shortened to their number.
  static const rerunnableSteps = ['0002'];

  /// Runs the pending steps. A [dryRun] reports them and writes nothing.
  ///
  /// With [rerun], runs only the step of that number, even if it was recorded,
  /// for one that skipped something that can be retried.
  Future<List<MigrationOutcome>> run(
      {bool dryRun = false, String? rerun}) async {
    if (!dryRun) await accounts.store.ensureIndexes();
    if (rerun != null) return [await _rerun(rerun, dryRun)];
    final collection = db.collection(migrationCollection);
    final outcomes = <MigrationOutcome>[];
    for (final step in _steps) {
      if (await collection.findOne(where.eq('_id', step.id)) != null) {
        outcomes.add(MigrationOutcome(
            step.id, MigrationStatus.alreadyApplied, const []));
        continue;
      }
      final changes = await step.apply(dryRun);
      if (dryRun) {
        outcomes.add(
            MigrationOutcome(step.id, MigrationStatus.wouldApply, changes));
        continue;
      }
      final result = await collection.insertOne({
        '_id': step.id,
        'appliedAt': accounts.clock(),
        'changes': changes.length,
      });
      if (result.hasWriteErrors &&
          result.writeError?.code != _duplicateKeyCode) {
        throw StateError(
            'cannot record ${step.id}: ${result.writeError?.errmsg}');
      }
      outcomes.add(MigrationOutcome(step.id, MigrationStatus.applied, changes));
    }
    return outcomes;
  }

  Future<MigrationOutcome> _rerun(String number, bool dryRun) async {
    final step = _steps
        .where((step) => step.rerunnable && step.id.startsWith('${number}_'))
        .firstOrNull;
    if (step == null) {
      throw ArgumentError.value(number, 'rerun', 'cannot be run again');
    }
    final changes = await step.apply(dryRun);
    if (dryRun) {
      return MigrationOutcome(step.id, MigrationStatus.wouldApply, changes);
    }
    final now = accounts.clock();
    final result = await db.collection(migrationCollection).updateOne(
        where.eq('_id', step.id),
        modify
            .set('lastRerunAt', now)
            .setOnInsert('appliedAt', now)
            .setOnInsert('changes', changes.length),
        upsert: true);
    if (result.hasWriteErrors && result.writeError?.code != _duplicateKeyCode) {
      throw StateError(
          'cannot record ${step.id}: ${result.writeError?.errmsg}');
    }
    return MigrationOutcome(step.id, MigrationStatus.applied, changes);
  }

  /// Creates a placeholder user for every email in `packages.uploaders`.
  Future<List<String>> _usersFromUploaders(bool dryRun) async {
    final reply = await db.collection(packageCollection).distinct('uploaders');
    final emails = <String>{};
    final changes = <String>[];
    for (final value in reply['values'] as List) {
      final email = value is String ? normalizeEmail(value) : '';
      if (isValidEmail(email)) {
        emails.add(email);
      } else {
        changes.add('skip invalid uploader "$value"');
      }
    }

    final bootstrapEmail = normalizeEmail(auth.bootstrapEmail);
    for (final email in emails.toList()..sort()) {
      if (await accounts.store.findUserByEmail(email) != null) continue;
      final role = email == bootstrapEmail ? Role.admin : Role.publisher;
      if (!dryRun) {
        try {
          await accounts.createUser(
            email: email,
            role: role,
            auditDetails: const {'migration': '0001_users_from_uploaders'},
          );
        } on AccountException catch (error) {
          if (error.statusCode != 409) rethrow;
          continue;
        }
      }
      changes.add('create placeholder user $email with role ${role.name}');
    }
    return changes;
  }

  /// Records the hash of each stored archive that has none yet.
  Future<List<String>> _versionSha256(bool dryRun) async {
    final packages = db.collection(packageCollection);
    final documents = await packages
        .find(where.fields(['name', 'versions.version', 'versions.sha256']))
        .toList();
    final changes = <String>[];
    for (final document in documents) {
      final name = document['name'] as String;
      for (final item in (document['versions'] as List? ?? const [])) {
        if (item['sha256'] != null) continue;
        final version = item['version'] as String;
        if (!await packageStore.exists(name, version)) {
          _log.warning(LogEvent('skipping a version whose archive is missing',
              {'name': name, 'version': version}));
          changes.add('skip $name@$version: archive missing');
          continue;
        }
        if (dryRun) {
          changes.add('hash $name@$version');
          continue;
        }
        final digest =
            await sha256.bind(packageStore.download(name, version)).first;
        final result = await packages.updateOne({
          'name': name,
          'versions': {
            r'$elemMatch': {
              'version': version,
              'sha256': {r'$exists': false},
            },
          },
        }, modify.set(r'versions.$.sha256', digest.toString()));
        if (result.hasWriteErrors || !result.operationSucceeded) {
          throw StateError('cannot store the hash of $name@$version: '
              '${result.writeError?.errmsg ?? result.errmsg}');
        }
        changes.add('hash $name@$version');
      }
    }
    return changes;
  }
}
