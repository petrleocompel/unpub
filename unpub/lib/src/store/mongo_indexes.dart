import 'package:mongo_dart/mongo_dart.dart';

/// Creates [indexes] on [collection], which is safe to repeat.
///
/// Issued as a raw command because `DbCollection.createIndex` cannot set
/// `expireAfterSeconds`.
Future<void> createIndexes(
    Db db, String collection, List<Map<String, Object>> indexes) async {
  final reply = await db.runCommand({
    'createIndexes': collection,
    'indexes': indexes,
  });
  if (reply['ok'] != 1 && reply['ok'] != 1.0) {
    throw StateError(
        'cannot create indexes on $collection: ${reply['errmsg']}');
  }
}

/// The error code of a command on a collection that does not exist.
const _namespaceNotFound = 26;

/// The index of [collection] called [name], or null if there is none.
Future<Map<String, dynamic>?> findIndex(
    Db db, String collection, String name) async {
  final Map<String, dynamic> reply;
  try {
    reply = await db.runCommand({'listIndexes': collection});
  } on MongoDartError catch (error) {
    if (error.mongoCode == _namespaceNotFound) return null;
    rethrow;
  } on Map catch (error) {
    if (error['code'] == _namespaceNotFound) return null;
    rethrow;
  }
  if (reply['code'] == _namespaceNotFound) return null;
  if (reply['ok'] != 1 && reply['ok'] != 1.0) {
    throw StateError(
        'cannot list the indexes of $collection: ${reply['errmsg']}');
  }
  final cursor = reply['cursor'] as Map?;
  for (final index in cursor?['firstBatch'] as List? ?? const []) {
    if (index is Map && index['name'] == name) {
      return Map<String, dynamic>.from(index);
    }
  }
  return null;
}

/// Makes the TTL index [name] on [field] of [collection] expire documents
/// after [expireAfter], creating or changing it as needed, or drops it when
/// [expireAfter] is null or zero, which keeps documents forever.
///
/// Run at every start, so that the index follows the configuration.
Future<void> syncTtlIndex(
  Db db,
  String collection, {
  required String name,
  required String field,
  required Duration? expireAfter,
}) async {
  final existing = await findIndex(db, collection, name);
  final seconds = expireAfter?.inSeconds ?? 0;
  if (seconds <= 0) {
    if (existing == null) return;
    final reply =
        await db.runCommand({'dropIndexes': collection, 'index': name});
    if (reply['ok'] != 1 && reply['ok'] != 1.0) {
      throw StateError('cannot drop index $name of $collection: '
          '${reply['errmsg']}');
    }
    return;
  }
  if (existing == null) {
    await createIndexes(db, collection, [
      {
        'key': {field: 1},
        'name': name,
        'expireAfterSeconds': seconds,
      },
    ]);
    return;
  }
  final current = (existing['expireAfterSeconds'] as num?)?.toInt();
  if (current == seconds) return;
  final reply = await db.runCommand({
    'collMod': collection,
    'index': {'name': name, 'expireAfterSeconds': seconds},
  });
  if (reply['ok'] != 1 && reply['ok'] != 1.0) {
    throw StateError('cannot change index $name of $collection: '
        '${reply['errmsg']}');
  }
}
