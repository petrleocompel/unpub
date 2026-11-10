import 'package:mongo_dart/mongo_dart.dart';

import '../store/mongo_indexes.dart';

final webhookCollection = 'webhooks';
final webhookDeliveryCollection = 'webhook_deliveries';

/// The TTL index that applies `webhooks.retentionDays` to finished
/// deliveries.
const webhookDeliveryRetentionIndex = 'finished_at_ttl';

/// The events a webhook can subscribe to.
const webhookEvents = [
  'package.published',
  'version.retracted',
  'version.unretracted',
  'package.discontinued',
  'package.continued',
  'version.deleted',
  'package.deleted',
];

/// Where a delivery stands.
abstract final class DeliveryStatus {
  /// Waiting for its next attempt, or being attempted under a claim.
  static const pending = 'pending';
  static const succeeded = 'succeeded';

  /// Given up, after `webhooks.maxAttempts` or a refusal that a retry cannot
  /// change.
  static const failed = 'failed';
}

/// A registered receiver of events.
class Webhook {
  final String id;
  final Uri url;
  final List<String> events;
  final String description;
  final bool enabled;

  /// The key of the signatures. Stored as is, because signing needs it.
  final String secret;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? createdBy;

  const Webhook({
    required this.id,
    required this.url,
    required this.events,
    required this.description,
    required this.enabled,
    required this.secret,
    required this.createdAt,
    required this.updatedAt,
    this.createdBy,
  });

  factory Webhook.fromDocument(Map<String, dynamic> document) => Webhook(
        id: (document['_id'] as ObjectId).oid,
        url: Uri.parse(document['url'] as String),
        events: [for (final event in document['events'] as List) '$event'],
        description: document['description'] as String? ?? '',
        enabled: document['enabled'] as bool? ?? true,
        secret: document['secret'] as String,
        createdAt: document['createdAt'] as DateTime,
        updatedAt: document['updatedAt'] as DateTime,
        createdBy: document['createdBy'] as String?,
      );

  /// Without the secret, which is only shown when it is made.
  Map<String, Object?> toJson() => {
        'id': id,
        'url': '$url',
        'events': events,
        'description': description,
        'enabled': enabled,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'createdBy': createdBy,
      };
}

/// One event for one webhook, with its attempts so far.
class Delivery {
  final String id;
  final String webhookId;
  final String event;

  /// The `id` in the payload, shared by a redelivery.
  final String eventId;
  final String? package;
  final String? version;

  /// The exact body that is sent and signed.
  final String payload;
  final String status;

  /// Attempts made so far.
  final int attempt;
  final DateTime nextAt;
  final DateTime createdAt;
  final DateTime? lastAttemptAt;
  final DateTime? finishedAt;

  /// The status code of the last answer, if there was one.
  final int? responseStatus;

  /// The start of the last answer, at most 1 KiB.
  final String? responseBody;
  final String? error;

  /// The delivery this one sends again.
  final String? redeliveryOf;

  const Delivery({
    required this.id,
    required this.webhookId,
    required this.event,
    required this.eventId,
    this.package,
    this.version,
    required this.payload,
    required this.status,
    required this.attempt,
    required this.nextAt,
    required this.createdAt,
    this.lastAttemptAt,
    this.finishedAt,
    this.responseStatus,
    this.responseBody,
    this.error,
    this.redeliveryOf,
  });

  factory Delivery.fromDocument(Map<String, dynamic> document) {
    final response = document['response'] as Map?;
    return Delivery(
      id: (document['_id'] as ObjectId).oid,
      webhookId: document['webhookId'] as String,
      event: document['event'] as String,
      eventId: document['eventId'] as String,
      package: document['package'] as String?,
      version: document['version'] as String?,
      payload: document['payload'] as String,
      status: document['status'] as String,
      attempt: (document['attempt'] as num?)?.toInt() ?? 0,
      nextAt: document['nextAt'] as DateTime,
      createdAt: document['createdAt'] as DateTime,
      lastAttemptAt: document['lastAttemptAt'] as DateTime?,
      finishedAt: document['finishedAt'] as DateTime?,
      responseStatus: (response?['status'] as num?)?.toInt(),
      responseBody: response?['body'] as String?,
      error: document['error'] as String?,
      redeliveryOf: document['redeliveryOf'] as String?,
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'webhookId': webhookId,
        'event': event,
        'eventId': eventId,
        'package': package,
        'version': version,
        'status': status,
        'attempt': attempt,
        'nextAt': status == DeliveryStatus.pending
            ? nextAt.toUtc().toIso8601String()
            : null,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'lastAttemptAt': lastAttemptAt?.toUtc().toIso8601String(),
        'finishedAt': finishedAt?.toUtc().toIso8601String(),
        'response': responseStatus == null && responseBody == null
            ? null
            : {'status': responseStatus, 'body': responseBody},
        'error': error,
        'redeliveryOf': redeliveryOf,
      };
}

/// The id of a stored document, or null if [id] cannot be one.
ObjectId? parseObjectId(String id) {
  if (!RegExp(r'^[0-9a-f]{24}$').hasMatch(id)) return null;
  return ObjectId.fromHexString(id);
}

/// The `webhooks` and `webhook_deliveries` collections.
///
/// Every time the queue compares is taken from the database, so that
/// instances whose clocks disagree still agree on what is due and on when a
/// claim has run out.
class WebhookStore {
  final Db db;

  const WebhookStore(this.db);

  DbCollection get _hooks => db.collection(webhookCollection);
  DbCollection get _deliveries => db.collection(webhookDeliveryCollection);

  /// The clock of the database.
  Future<DateTime> now() async {
    final reply = await db.runCommand({'isMaster': 1});
    final now = reply['localTime'];
    if (now is! DateTime) {
      throw StateError('cannot read the clock of the database');
    }
    return now;
  }

  /// Creates the indexes of the queue, and makes the TTL index of finished
  /// deliveries match [retention], dropping it when that is null.
  Future<void> ensureIndexes({Duration? retention}) async {
    await createIndexes(db, webhookDeliveryCollection, [
      {
        'key': {'status': 1, 'nextAt': 1},
        'name': 'status_next_at',
      },
      {
        'key': {'webhookId': 1, 'createdAt': -1},
        'name': 'webhook_created_at',
      },
    ]);
    await syncTtlIndex(db, webhookDeliveryCollection,
        name: webhookDeliveryRetentionIndex,
        field: 'finishedAt',
        expireAfter: retention);
  }

  static void _check(WriteResult result, String action) {
    if (result.hasWriteErrors || !result.operationSucceeded) {
      throw StateError('cannot $action: '
          '${result.writeError?.errmsg ?? result.errmsg}');
    }
  }

  Future<List<Webhook>> list() async => [
        await for (final document in _hooks.modernFind(sort: {'createdAt': 1}))
          Webhook.fromDocument(document),
      ];

  Future<Webhook?> find(String id) async {
    final objectId = parseObjectId(id);
    if (objectId == null) return null;
    final document = await _hooks.findOne(where.id(objectId));
    return document == null ? null : Webhook.fromDocument(document);
  }

  /// The enabled webhooks that subscribe to [event].
  Future<List<Webhook>> subscribers(String event) async => [
        await for (final document in _hooks.modernFind(filter: {
          'enabled': true,
          'events': event,
        }))
          Webhook.fromDocument(document),
      ];

  Future<Webhook> insert({
    required Uri url,
    required List<String> events,
    required String description,
    required String secret,
    String? createdBy,
  }) async {
    final now = await this.now();
    final id = ObjectId();
    final result = await _hooks.insertOne({
      '_id': id,
      'url': '$url',
      'events': events,
      'description': description,
      'enabled': true,
      'secret': secret,
      'createdAt': now,
      'updatedAt': now,
      'createdBy': createdBy,
    });
    _check(result, 'create webhook');
    return (await find(id.oid))!;
  }

  /// Sets the given fields, and returns whether the webhook exists.
  Future<bool> update(String id, Map<String, Object> fields) async {
    final objectId = parseObjectId(id);
    if (objectId == null) return false;
    final result = await _hooks.updateOne(where.id(objectId), {
      r'$set': {...fields, 'updatedAt': await now()},
    });
    _check(result, 'update webhook');
    return result.nMatched == 1;
  }

  /// Deletes the webhook and its deliveries, and returns whether it existed.
  Future<bool> delete(String id) async {
    final objectId = parseObjectId(id);
    if (objectId == null) return false;
    final result = await _hooks.deleteOne(where.id(objectId));
    if (result.nRemoved != 1) return false;
    await _deliveries.deleteMany(where.eq('webhookId', id));
    return true;
  }

  /// Queues [payload] for each of [hooks], due now.
  Future<void> enqueue(
    List<Webhook> hooks, {
    required String event,
    required String eventId,
    required String payload,
    String? package,
    String? version,
    String? redeliveryOf,
  }) async {
    if (hooks.isEmpty) return;
    final now = await this.now();
    final result = await _deliveries.insertMany([
      for (final hook in hooks)
        {
          'webhookId': hook.id,
          'event': event,
          'eventId': eventId,
          if (package != null) 'package': package,
          if (version != null) 'version': version,
          'payload': payload,
          'status': DeliveryStatus.pending,
          'attempt': 0,
          'nextAt': now,
          'createdAt': now,
          if (redeliveryOf != null) 'redeliveryOf': redeliveryOf,
        },
    ]);
    if (result.hasWriteErrors || !result.isSuccess) {
      throw StateError('cannot queue webhook deliveries');
    }
  }

  /// The newest deliveries of [webhookId].
  Future<List<Delivery>> deliveries(String webhookId, {int limit = 50}) async =>
      [
        await for (final document in _deliveries.modernFind(
            filter: {'webhookId': webhookId},
            sort: {'createdAt': -1, '_id': -1},
            limit: limit))
          Delivery.fromDocument(document),
      ];

  Future<Delivery?> delivery(String webhookId, String id) async {
    final objectId = parseObjectId(id);
    if (objectId == null) return null;
    final document = await _deliveries
        .findOne(where.id(objectId).eq('webhookId', webhookId));
    return document == null ? null : Delivery.fromDocument(document);
  }

  /// Claims the delivery that has been due the longest for [owner], for
  /// [lease], or returns null if none is due. A claim that ran out, because
  /// its holder stopped, can be taken over.
  Future<Delivery?> claim(String owner, Duration lease) async {
    final now = await this.now();
    final result = await _deliveries.modernFindAndModify(
      query: {
        'status': DeliveryStatus.pending,
        'nextAt': {r'$lte': now},
        r'$or': [
          {'claimedUntil': null},
          {
            'claimedUntil': {r'$lt': now},
          },
        ],
      },
      sort: {'nextAt': 1},
      update: {
        r'$set': {'claimedBy': owner, 'claimedUntil': now.add(lease)},
      },
      returnNew: true,
    );
    if (result.failure) {
      throw StateError('cannot claim a webhook delivery: ${result.errmsg}');
    }
    final document = result.value;
    return document == null ? null : Delivery.fromDocument(document);
  }

  /// Records the outcome of an attempt of [owner], which has to still hold
  /// the claim. Returns whether it did.
  Future<bool> finishAttempt(
    Delivery delivery,
    String owner, {
    required String status,
    required int attempt,
    DateTime? nextAt,
    int? responseStatus,
    String? responseBody,
    String? error,
  }) async {
    final now = await this.now();
    final result = await _deliveries.updateOne({
      '_id': parseObjectId(delivery.id),
      'claimedBy': owner,
    }, {
      r'$set': {
        'status': status,
        'attempt': attempt,
        'lastAttemptAt': now,
        if (nextAt != null) 'nextAt': nextAt,
        if (status != DeliveryStatus.pending) 'finishedAt': now,
        'response': responseStatus == null && responseBody == null
            ? null
            : {'status': responseStatus, 'body': responseBody},
        'error': error,
      },
      r'$unset': {'claimedBy': '', 'claimedUntil': ''},
    });
    _check(result, 'record a webhook delivery');
    return result.nMatched == 1;
  }

  /// Counts the deliveries of [webhookId] by status.
  Future<Map<String, int>> statusCounts(String webhookId) async {
    final counts = <String, int>{};
    for (final status in [
      DeliveryStatus.pending,
      DeliveryStatus.succeeded,
      DeliveryStatus.failed,
    ]) {
      counts[status] = (await _deliveries
              .modernCount(filter: {'webhookId': webhookId, 'status': status}))
          .count;
    }
    return counts;
  }
}
