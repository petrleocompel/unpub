import 'package:mongo_dart/mongo_dart.dart';

import 'mongo_indexes.dart';

final upstreamCacheCollection = 'upstream_cache';

const _duplicateKeyCode = 11000;

/// A copy of something fetched from the upstream.
class UpstreamCacheEntry {
  /// A package name for a listing, or `advisories:<name>`.
  final String key;

  /// The cached JSON, kept as text because pubspecs can hold keys that MongoDB
  /// does not accept in a document.
  final String body;

  /// JSON map of version to upstream archive URL, for a listing.
  final String? archiveUrls;

  /// The upstream's validator, for revalidating when the entry has gone stale.
  final String? etag;
  final DateTime fetchedAt;

  const UpstreamCacheEntry({
    required this.key,
    required this.body,
    this.archiveUrls,
    this.etag,
    required this.fetchedAt,
  });
}

/// Where upstream metadata is kept between requests.
abstract class UpstreamCacheStore {
  Future<UpstreamCacheEntry?> read(String key);

  /// Stores [entry], to be forgotten after [expiresAt].
  Future<void> write(UpstreamCacheEntry entry, DateTime expiresAt);

  /// Records that the upstream confirmed the entry at [fetchedAt] is current.
  Future<void> touch(String key, DateTime fetchedAt, DateTime expiresAt);

  Future<void> delete(String key);
}

/// Keeps entries in the `upstream_cache` collection.
///
/// Expiry goes through a dedicated `expiresAt` field, because the TTL of an
/// index on `fetchedAt` could not change along with `upstream.cacheTtl`.
class MongoUpstreamCacheStore implements UpstreamCacheStore {
  final Db db;

  const MongoUpstreamCacheStore(this.db);

  DbCollection get _collection => db.collection(upstreamCacheCollection);

  Future<void> ensureIndexes() async {
    await createIndexes(db, upstreamCacheCollection, [
      {
        'key': {'expiresAt': 1},
        'name': 'expires_at_ttl',
        'expireAfterSeconds': 0,
      },
    ]);
  }

  @override
  Future<UpstreamCacheEntry?> read(String key) async {
    final document = await _collection.findOne(where.eq('_id', key));
    if (document == null) return null;
    return UpstreamCacheEntry(
      key: key,
      body: document['body'] as String,
      archiveUrls: document['archiveUrls'] as String?,
      etag: document['etag'] as String?,
      fetchedAt: document['fetchedAt'] as DateTime,
    );
  }

  @override
  Future<void> write(UpstreamCacheEntry entry, DateTime expiresAt) async {
    var update = modify
        .set('private', false)
        .set('body', entry.body)
        .set('fetchedAt', entry.fetchedAt)
        .set('expiresAt', expiresAt);
    update = entry.archiveUrls == null
        ? update.unset('archiveUrls')
        : update.set('archiveUrls', entry.archiveUrls);
    update = entry.etag == null
        ? update.unset('etag')
        : update.set('etag', entry.etag);
    final result = await _collection
        .updateOne(where.eq('_id', entry.key), update, upsert: true);
    // Losing the race to create the entry means another request just stored
    // the same upstream response.
    if (result.hasWriteErrors && result.writeError?.code != _duplicateKeyCode) {
      throw StateError('cannot cache ${entry.key}: '
          '${result.writeError?.errmsg}');
    }
  }

  @override
  Future<void> touch(String key, DateTime fetchedAt, DateTime expiresAt) async {
    await _collection.updateOne(where.eq('_id', key),
        modify.set('fetchedAt', fetchedAt).set('expiresAt', expiresAt));
  }

  @override
  Future<void> delete(String key) async {
    await _collection.deleteOne(where.eq('_id', key));
  }
}
