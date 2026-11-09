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
