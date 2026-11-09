import 'package:logging/logging.dart';
import 'package:mongo_dart/mongo_dart.dart';

import '../logging.dart';
import 'mongo_indexes.dart';

final auditCollection = 'audit';

final _log = Logger('unpub.audit');

/// Something that happened and must remain traceable.
class AuditEvent {
  final DateTime at;

  /// An email address, `token:<prefix>` or `system`.
  final String actor;
  final String action;

  /// The package, version, user or token acted on.
  final String target;
  final Map<String, Object?> details;
  final String? ip;

  AuditEvent({
    DateTime? at,
    required this.actor,
    required this.action,
    required this.target,
    this.details = const {},
    this.ip,
  }) : at = at ?? DateTime.now();
}

/// Where audit events are kept.
abstract class AuditStore {
  const AuditStore();

  /// Stores [event], throwing if it cannot be stored.
  Future<void> record(AuditEvent event);

  /// Stores [event] after the action it describes has already happened, when
  /// failing the request would misreport that action. A loss is logged.
  Future<void> recordSafely(AuditEvent event) async {
    try {
      await record(event);
    } catch (error, stackTrace) {
      _log.severe(
          LogEvent('failed to record audit event',
              {'action': event.action, 'target': event.target}),
          error,
          stackTrace);
    }
  }
}

/// Discards events, for embedders without an audit trail.
class NullAuditStore extends AuditStore {
  const NullAuditStore();

  @override
  Future<void> record(AuditEvent event) async {}
}

/// Keeps events in the `audit` collection.
class MongoAuditStore extends AuditStore {
  final Db db;

  const MongoAuditStore(this.db);

  Future<void> ensureIndexes() async {
    await createIndexes(db, auditCollection, [
      {
        'key': {'at': -1},
        'name': 'at_desc',
      },
    ]);
  }

  @override
  Future<void> record(AuditEvent event) async {
    await db.collection(auditCollection).insertOne({
      'at': event.at,
      'actor': event.actor,
      'action': event.action,
      'target': event.target,
      'details': event.details,
      'ip': event.ip,
    });
  }
}
