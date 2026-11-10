import 'package:logging/logging.dart';
import 'package:mongo_dart/mongo_dart.dart';

import '../logging.dart';
import 'mongo_indexes.dart';

final auditCollection = 'audit';

/// The TTL index that applies `audit.retentionDays`.
const auditRetentionIndex = 'at_ttl';

/// The most events one page of [AuditStore.query] holds.
const maxAuditPageSize = 200;

final _log = Logger('unpub.audit');

/// Every action the server records, for the filter of the audit page.
const auditActions = [
  'package.published',
  'version.retracted',
  'version.unretracted',
  'version.deleted',
  'package.discontinued',
  'package.continued',
  'package.deleted',
  'uploader.added',
  'uploader.removed',
  'uploader.transferred',
  'user.created',
  'user.updated',
  'user.role_changed',
  'user.disabled',
  'user.enabled',
  'user.password_set',
  'user.login',
  'user.login_failed',
  'token.created',
  'token.revoked',
  'webhook.created',
  'webhook.updated',
  'webhook.secret_rotated',
  'webhook.deleted',
  'webhook.redelivered',
];

/// How the actor of an [AuditEvent] proved who it is.
abstract final class AuditActorKind {
  /// A web session started by a password login.
  static const session = 'session';

  /// A personal API token, named by [AuditEvent.token].
  static const apiToken = 'apiToken';

  /// A deprecated token from the configuration.
  static const staticToken = 'staticToken';

  /// A password, when logging in.
  static const password = 'password';

  /// Nobody proved anything, as in a failed login.
  static const anonymous = 'anonymous';

  /// The server itself, or an operator at the command line.
  static const system = 'system';
}

/// Something that happened and must remain traceable.
///
/// Every event has the same fields, so that the log can be filtered by any of
/// them: [package] and [version] for what a package event is about, [target]
/// for a user, token or webhook acted on.
class AuditEvent {
  final DateTime at;

  /// The email of whoever acted, `system`, or the address a failed login
  /// tried.
  final String actor;

  /// One of [AuditActorKind].
  final String actorKind;

  /// The prefix of the API token that acted, if one did.
  final String? token;

  final String action;
  final String? package;
  final String? version;

  /// The user (by email), token (`token:<prefix>`) or webhook (`webhook:<id>`)
  /// acted on.
  final String? target;
  final Map<String, Object?> details;
  final String? ip;

  AuditEvent({
    DateTime? at,
    required this.actor,
    this.actorKind = AuditActorKind.system,
    this.token,
    required this.action,
    this.package,
    this.version,
    this.target,
    this.details = const {},
    this.ip,
  }) : at = at ?? DateTime.now();

  /// An event read back from the `audit` collection, also one written before
  /// the fields were settled, whose `target` may name a package.
  factory AuditEvent.fromDocument(Map<String, dynamic> document) => AuditEvent(
        at: document['at'] is DateTime
            ? document['at'] as DateTime
            : DateTime.fromMillisecondsSinceEpoch(0),
        actor: '${document['actor'] ?? ''}',
        actorKind: document['actorKind'] as String? ?? AuditActorKind.system,
        token: document['token'] as String?,
        action: '${document['action'] ?? ''}',
        package: document['package'] as String?,
        version: document['version'] as String?,
        target: document['target'] as String?,
        details: document['details'] is Map
            ? Map<String, Object?>.from(document['details'] as Map)
            : const {},
        ip: document['ip'] as String?,
      );

  Map<String, Object?> toDocument() => {
        'at': at,
        'action': action,
        'actor': actor,
        'actorKind': actorKind,
        if (token != null) 'token': token,
        if (package != null) 'package': package,
        if (version != null) 'version': version,
        if (target != null) 'target': target,
        'details': details,
        'ip': ip,
      };

  /// The JSON form of `GET /webapi/audit`.
  Map<String, Object?> toJson() => {
        'at': at.toUtc().toIso8601String(),
        'action': action,
        'actor': actor,
        'actorKind': actorKind,
        'token': token,
        'package': package,
        'version': version,
        'target': target,
        'ip': ip,
        'details': _jsonSafe(details),
      };

  static Object? _jsonSafe(Object? value) => switch (value) {
        null || String() || num() || bool() => value,
        DateTime() => value.toUtc().toIso8601String(),
        Map() => {
            for (final entry in value.entries)
              '${entry.key}': _jsonSafe(entry.value),
          },
        Iterable() => [for (final item in value) _jsonSafe(item)],
        _ => '$value',
      };
}

/// Which events [AuditStore.query] returns, newest first.
class AuditQuery {
  final String? action;

  /// An actor email, or `token:<prefix>` for the events of one token.
  final String? actor;
  final String? package;

  /// Inclusive.
  final DateTime? from;

  /// Exclusive.
  final DateTime? to;

  /// One-based.
  final int page;
  final int size;

  const AuditQuery({
    this.action,
    this.actor,
    this.package,
    this.from,
    this.to,
    this.page = 1,
    this.size = 50,
  });

  /// The query given by the parameters `action`, `actor`, `package`, `from`,
  /// `to`, `page` and `size` of a request. A [to] that is a date without a time
  /// includes that whole day, and dates without a time zone are in UTC.
  ///
  /// Throws a [FormatException] saying which parameter is wrong.
  factory AuditQuery.fromParameters(Map<String, String> parameters,
      {int defaultSize = 50}) {
    String? text(String name) {
      final value = parameters[name]?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    int number(String name, int fallback) {
      final value = text(name);
      if (value == null) return fallback;
      final parsed = int.tryParse(value);
      if (parsed == null || parsed < 1) {
        throw FormatException('$name must be a positive integer');
      }
      return parsed;
    }

    final size = number('size', defaultSize);
    if (size > maxAuditPageSize) {
      throw const FormatException('size must be at most $maxAuditPageSize');
    }
    return AuditQuery(
      action: text('action'),
      actor: text('actor'),
      package: text('package'),
      from: _time(text('from'), 'from', endOfDay: false),
      to: _time(text('to'), 'to', endOfDay: true),
      page: number('page', 1),
      size: size,
    );
  }

  static final _datePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');
  static final _zonePattern = RegExp(r'(Z|[+-]\d{2}(:?\d{2})?)$');

  static DateTime? _time(String? text, String name, {required bool endOfDay}) {
    if (text == null) return null;
    final date = _datePattern.hasMatch(text);
    final parsed = DateTime.tryParse(
        date || _zonePattern.hasMatch(text) ? text : '${text}Z');
    if (parsed == null) {
      throw FormatException('$name must be an ISO 8601 date or time, such as '
          '2026-11-10 or 2026-11-10T08:30:00Z');
    }
    if (!date) return parsed.toUtc();
    final day = DateTime.utc(parsed.year, parsed.month, parsed.day);
    return endOfDay ? day.add(const Duration(days: 1)) : day;
  }

  /// The parameters giving this query, without the page.
  Map<String, String> get parameters => {
        if (action != null) 'action': action!,
        if (actor != null) 'actor': actor!,
        if (package != null) 'package': package!,
        if (from != null) 'from': from!.toUtc().toIso8601String(),
        if (to != null) 'to': to!.toUtc().toIso8601String(),
      };

  int get limit => size.clamp(1, maxAuditPageSize);

  int get offset => (page.clamp(1, 1 << 20) - 1) * limit;

  Map<String, Object> get filter {
    final actor = this.actor;
    return {
      if (action != null) 'action': action!,
      if (actor != null)
        if (actor.startsWith('token:'))
          'token': actor.substring('token:'.length)
        else
          'actor': actor,
      if (package != null) 'package': package!,
      if (from != null || to != null)
        'at': {
          if (from != null) r'$gte': from!,
          if (to != null) r'$lt': to!,
        },
    };
  }
}

/// One page of events, and how many match in all.
class AuditPage {
  final List<AuditEvent> events;
  final int count;

  const AuditPage(this.events, this.count);
}

/// Where audit events are kept.
abstract class AuditStore {
  const AuditStore();

  /// Stores [event], throwing if it cannot be stored.
  Future<void> record(AuditEvent event);

  /// The events matching [query]. A store that cannot be read has none.
  Future<AuditPage> query(AuditQuery query) async => const AuditPage([], 0);

  /// Stores [event] after the action it describes has already happened, when
  /// failing the request would misreport that action. A loss is logged.
  Future<void> recordSafely(AuditEvent event) async {
    try {
      await record(event);
    } catch (error, stackTrace) {
      _log.severe(
          LogEvent('failed to record audit event', {
            'action': event.action,
            if (event.package != null) 'package': event.package,
            if (event.target != null) 'target': event.target,
          }),
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

  DbCollection get _events => db.collection(auditCollection);

  /// Creates the indexes of the queries, and makes the TTL index match
  /// [retention], dropping it when that is null: events are then kept for
  /// good.
  Future<void> ensureIndexes({Duration? retention}) async {
    await createIndexes(db, auditCollection, [
      {
        'key': {'at': -1},
        'name': 'at_desc',
      },
      {
        'key': {'package': 1, 'at': -1},
        'name': 'package_at',
      },
      {
        'key': {'actor': 1, 'at': -1},
        'name': 'actor_at',
      },
      {
        'key': {'action': 1, 'at': -1},
        'name': 'action_at',
      },
    ]);
    await syncTtlIndex(db, auditCollection,
        name: auditRetentionIndex, field: 'at', expireAfter: retention);
  }

  @override
  Future<void> record(AuditEvent event) async {
    final result = await _events.insertOne(event.toDocument());
    if (result.hasWriteErrors) {
      throw StateError(
          'cannot store audit event: ${result.writeError?.errmsg}');
    }
  }

  @override
  Future<AuditPage> query(AuditQuery query) async {
    final filter = query.filter;
    final count = await _events.modernCount(filter: filter);
    final events = await _events
        .modernFind(
          filter: filter,
          sort: {'at': -1, '_id': -1},
          skip: query.offset > 0 ? query.offset : null,
          limit: query.limit,
        )
        .map(AuditEvent.fromDocument)
        .toList();
    return AuditPage(events, count.count);
  }
}
