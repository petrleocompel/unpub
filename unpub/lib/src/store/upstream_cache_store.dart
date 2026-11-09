import 'package:mongo_dart/mongo_dart.dart';

import 'mongo_indexes.dart';

final upstreamCacheCollection = 'upstream_cache';
final upstreamArchivesCollection = 'upstream_archives';

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

  /// Versions whose `archive_sha256` was not a SHA-256, for a listing.
  final List<String> invalidHashes;

  /// The upstream's validator, for revalidating when the entry has gone stale.
  final String? etag;
  final DateTime fetchedAt;

  const UpstreamCacheEntry({
    required this.key,
    required this.body,
    this.archiveUrls,
    this.invalidHashes = const [],
    this.etag,
    required this.fetchedAt,
  });
}

/// The one pointer to the archive kept from the upstream for a version: the
/// object it names is the one served, and it is replaced as a whole, so its
/// digest always matches the bytes of the object it points to.
class UpstreamArchiveRecord {
  final String name;
  final String version;

  /// Lowercase hex SHA-256 of the kept bytes, which also names the object.
  final String sha256;

  /// The size of the archive.
  final int bytes;
  final DateTime fetchedAt;

  /// Whether [sha256] matched a hash published by the upstream.
  final bool verified;

  const UpstreamArchiveRecord({
    required this.name,
    required this.version,
    required this.sha256,
    required this.bytes,
    required this.fetchedAt,
    required this.verified,
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

  /// The record of a kept archive, or null if none was written.
  Future<UpstreamArchiveRecord?> readArchive(String name, String version);

  Future<void> writeArchive(UpstreamArchiveRecord record);

  Future<void> deleteArchive(String name, String version);
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
      invalidHashes:
          (document['invalidHashes'] as List? ?? const []).cast<String>(),
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
    update = entry.invalidHashes.isEmpty
        ? update.unset('invalidHashes')
        : update.set('invalidHashes', entry.invalidHashes);
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

  DbCollection get _archives => db.collection(upstreamArchivesCollection);

  static String _archiveId(String name, String version) => '$name@$version';

  @override
  Future<UpstreamArchiveRecord?> readArchive(
      String name, String version) async {
    final document =
        await _archives.findOne(where.eq('_id', _archiveId(name, version)));
    if (document == null) return null;
    return UpstreamArchiveRecord(
      name: name,
      version: version,
      sha256: document['sha256'] as String,
      bytes: (document['bytes'] as num).toInt(),
      fetchedAt: document['fetchedAt'] as DateTime,
      verified: document['verified'] as bool,
    );
  }

  @override
  Future<void> writeArchive(UpstreamArchiveRecord record) async {
    final result = await _archives.updateOne(
        where.eq('_id', _archiveId(record.name, record.version)),
        modify
            .set('name', record.name)
            .set('version', record.version)
            .set('sha256', record.sha256)
            .set('bytes', record.bytes)
            .set('fetchedAt', record.fetchedAt)
            .set('verified', record.verified),
        upsert: true);
    // Losing the race to create the record means a concurrent fetch of the
    // same version just wrote it.
    if (result.hasWriteErrors && result.writeError?.code != _duplicateKeyCode) {
      throw StateError('cannot record ${record.name}@${record.version}: '
          '${result.writeError?.errmsg}');
    }
  }

  @override
  Future<void> deleteArchive(String name, String version) async {
    await _archives.deleteOne(where.eq('_id', _archiveId(name, version)));
  }
}
