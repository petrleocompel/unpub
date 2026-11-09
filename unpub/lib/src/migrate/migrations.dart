import 'package:mongo_dart/mongo_dart.dart';

import '../auth/account_service.dart';
import '../auth/accounts.dart';
import '../config/config.dart';
import '../store/mongo_store.dart';

final migrationCollection = 'migrations';

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

  const _Step(this.id, this.apply);
}

/// Applies each data migration once and records it in `migrations`.
///
/// A step also tolerates being repeated after a crash, because it is recorded
/// only once it has completely finished.
class Migrator {
  final Db db;
  final AccountService accounts;
  final AuthConfig auth;

  Migrator(this.db, this.accounts, this.auth);

  late final _steps = [
    _Step('0001_users_from_uploaders', _usersFromUploaders),
  ];

  /// Runs the pending steps. A [dryRun] reports them and writes nothing.
  Future<List<MigrationOutcome>> run({bool dryRun = false}) async {
    if (!dryRun) await accounts.store.ensureIndexes();
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
}
