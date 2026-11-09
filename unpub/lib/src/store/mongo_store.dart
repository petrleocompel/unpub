import 'package:intl/intl.dart';
import 'package:logging/logging.dart';
import 'package:mongo_dart/mongo_dart.dart';
import 'package:unpub/src/models.dart';

import '../config/config.dart' show uploadReservationTtl;
import 'meta_store.dart';
import 'mongo_indexes.dart';

final packageCollection = 'packages';
final statsCollection = 'stats';
final versionStatsCollection = 'version_stats';
final uploadReservationsCollection = 'upload_reservations';

const _duplicateKeyCode = 11000;

const _duplicateNamesReported = 20;

final _log = Logger('unpub.mongo');

class MongoStore extends MetaStore {
  Db db;

  MongoStore(this.db);

  /// Creates the indexes the store relies on, which is safe to repeat.
  ///
  /// The unique indexes keep two concurrent first publishes of a package from
  /// creating two documents, and two concurrent first downloads of a version
  /// from creating two counter documents.
  ///
  /// Throws if `packages` already holds a name twice, because publishing is not
  /// safe without the index.
  Future<void> ensureIndexes() async {
    await _ensureUniquePackageNames();
    await createIndexes(db, versionStatsCollection, [
      {
        'key': {'name': 1, 'version': 1},
        'name': 'name_version',
        'unique': true,
      },
    ]);
    await createIndexes(db, uploadReservationsCollection, [
      {
        'key': {'name': 1, 'version': 1},
        'name': 'name_version',
        'unique': true,
      },
      {
        'key': {'expiresAt': 1},
        'name': 'expires_at_ttl',
        'expireAfterSeconds': 0,
      },
    ]);
  }

  Future<void> _ensureUniquePackageNames() async {
    try {
      await createIndexes(db, packageCollection, [
        {
          'key': {'name': 1},
          'name': 'name_unique',
          'unique': true,
        },
      ]);
    } catch (error) {
      final duplicates = await _duplicatePackageNames();
      if (duplicates.isEmpty) rethrow;
      final message = 'cannot start: the packages collection holds more than '
          'one document for ${duplicates.join(', ')}. Merge or remove the extra '
          'documents, then start again.';
      _log.severe(message);
      throw StateError(message);
    }
  }

  /// Up to [_duplicateNamesReported] names held by more than one package.
  Future<List<String>> _duplicatePackageNames() async {
    final reply = await db.runCommand({
      'aggregate': packageCollection,
      'pipeline': [
        {
          r'$group': {
            '_id': r'$name',
            'count': {r'$sum': 1},
          },
        },
        {
          r'$match': {
            'count': {r'$gt': 1},
          },
        },
        {
          r'$sort': {'_id': 1},
        },
        {r'$limit': _duplicateNamesReported},
      ],
      'cursor': <String, Object>{},
    });
    final cursor = reply['cursor'] as Map?;
    return [
      for (final item in cursor?['firstBatch'] as List? ?? const [])
        '${item['_id']}',
    ];
  }

  static SelectorBuilder _selectByName(String? name) => where.eq('name', name);

  Future<UnpubQueryResult> _queryPackagesBySelector(
      SelectorBuilder selector) async {
    final count = await db.collection(packageCollection).count(selector);
    final packages = await db
        .collection(packageCollection)
        .find(selector)
        .map((item) => UnpubPackage.fromJson(item))
        .toList();
    return UnpubQueryResult(count, packages);
  }

  @override
  queryPackage(name) async {
    var json =
        await db.collection(packageCollection).findOne(_selectByName(name));
    if (json == null) return null;
    return UnpubPackage.fromJson(json);
  }

  @override
  addVersion(name, version) async {
    final packages = db.collection(packageCollection);
    final existing =
        await packages.findOne(_selectByName(name).fields(['_id']));
    if (existing == null) {
      final inserted = await packages.insertOne({
        'name': name,
        'versions': [version.toJson()],
        // Only a new package gets its first uploader. An administrator
        // publishing to someone else's package must not join it.
        'uploaders': [version.uploader],
        'private': true,
        'download': 0,
        'createdAt': version.createdAt,
        'updatedAt': version.createdAt,
      });
      if (inserted.writeError?.code != _duplicateKeyCode) {
        _checkWrite(inserted, 'add package');
        return;
      }
      // Another publish created the package first, so this is one more version
      // of it, or the same one.
    }
    // The condition keeps two concurrent publishes of one version from both
    // being added.
    final result = await packages.updateOne(
        where.eq('name', name).ne('versions.version', version.version),
        modify
            .push('versions', version.toJson())
            .set('updatedAt', version.createdAt));
    _checkWrite(result, 'add version');
    if (result.nMatched == 0) {
      throw VersionExistsException(name, version.version);
    }
  }

  @override
  Future<void> replaceVersion(String name, UnpubVersion version) async {
    final result = await db.collection(packageCollection).updateOne(
        where.eq('name', name).eq('versions.version', version.version),
        modify
            .set(r'versions.$', version.toJson())
            .set('updatedAt', version.createdAt));
    _checkWrite(result, 'replace version');
  }

  static void _checkWrite(WriteResult result, String action) {
    if (result.hasWriteErrors || !result.operationSucceeded) {
      throw StateError('cannot $action: '
          '${result.writeError?.errmsg ?? result.errmsg}');
    }
  }

  @override
  Future<String?> reserveUpload(String name, String version) async {
    final reservation = ObjectId().oid;
    final now = DateTime.now();
    final result = await db.collection(uploadReservationsCollection).insertOne({
      'name': name,
      'version': version,
      'reservation': reservation,
      'createdAt': now,
      'expiresAt': now.add(uploadReservationTtl),
    });
    if (result.writeError?.code == _duplicateKeyCode) return null;
    _checkWrite(result, 'reserve upload');
    return reservation;
  }

  @override
  Future<bool> renewUpload(
      String name, String version, String reservation) async {
    final result = await db.collection(uploadReservationsCollection).updateOne(
        where
            .eq('name', name)
            .eq('version', version)
            .eq('reservation', reservation),
        modify.set('expiresAt', DateTime.now().add(uploadReservationTtl)));
    _checkWrite(result, 'renew upload');
    return result.nMatched == 1;
  }

  @override
  Future<void> releaseUpload(
      String name, String version, String reservation) async {
    await db.collection(uploadReservationsCollection).deleteOne(where
        .eq('name', name)
        .eq('version', version)
        .eq('reservation', reservation));
  }

  @override
  addUploader(name, email) async {
    await db
        .collection(packageCollection)
        .update(_selectByName(name), modify.push('uploaders', email));
  }

  @override
  removeUploader(name, email) async {
    await db
        .collection(packageCollection)
        .update(_selectByName(name), modify.pull('uploaders', email));
  }

  @override
  increaseDownloads(name, version) {
    var today = DateFormat('yyyyMMdd').format(DateTime.now());
    Future.wait([
      db
          .collection(packageCollection)
          .update(_selectByName(name), modify.inc('download', 1)),
      db.collection(statsCollection).update(_selectByName(name),
          modify.inc('d$today', 1).setOnInsert('name', name),
          upsert: true),
      _countVersionDownload(name, version, today),
    ]).then<void>((_) {}, onError: (Object error, StackTrace stackTrace) {
      // Counting is best effort and must not fail the download.
      _log.warning('failed to count download of $name', error, stackTrace);
    });
  }

  Future<void> _countVersionDownload(
      String name, String version, String today) async {
    Future<WriteResult> count() =>
        db.collection(versionStatsCollection).updateOne(
            where.eq('name', name).eq('version', version),
            modify.inc('count', 1).inc('d$today', 1),
            upsert: true);

    var result = await count();
    // Losing the race to create the document leaves it there to increment.
    if (result.writeError?.code == _duplicateKeyCode) result = await count();
    _checkWrite(result, 'count version download');
  }

  @override
  Future<int> versionDownloads(String name, String version) async {
    final stats = await db
        .collection(versionStatsCollection)
        .findOne(where.eq('name', name).eq('version', version));
    return (stats?['count'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<Map<String, int>> versionDownloadCounts(
      String name, Iterable<String> versions) async {
    final stats = await db
        .collection(versionStatsCollection)
        .find(where.eq('name', name).fields(['version', 'count']))
        .toList();
    final counted = {
      for (final item in stats)
        item['version'] as String: (item['count'] as num?)?.toInt() ?? 0,
    };
    return {for (final version in versions) version: counted[version] ?? 0};
  }

  /// Selects [version] of [name] only while it is not yet in the target state,
  /// so that the first of two concurrent calls is the one that changes it.
  static Map<String, Object> _retractionSelector(
          String name, String version, bool retracted) =>
      {
        'name': name,
        'versions': {
          r'$elemMatch': {
            'version': version,
            'isRetracted': retracted ? {r'$ne': true} : true,
          },
        },
      };

  @override
  Future<bool> setVersionRetracted(
    String name,
    String version, {
    required bool retracted,
    DateTime? retractedAt,
    String? retractedBy,
  }) async {
    final result = await db.collection(packageCollection).updateOne(
        _retractionSelector(name, version, retracted),
        retracted
            ? {
                r'$set': {
                  r'versions.$.isRetracted': true,
                  r'versions.$.retractedAt': retractedAt,
                  r'versions.$.retractedBy': retractedBy,
                },
              }
            : {
                r'$unset': {
                  r'versions.$.isRetracted': '',
                  r'versions.$.retractedAt': '',
                  r'versions.$.retractedBy': '',
                },
              });
    _checkWrite(result, 'change retraction');
    return result.nModified == 1;
  }

  @override
  Future<void> setDiscontinued(
    String name, {
    required bool discontinued,
    String? replacedBy,
    DateTime? discontinuedAt,
  }) async {
    final set = {
      if (discontinued) 'isDiscontinued': true,
      if (discontinued) 'discontinuedAt': discontinuedAt,
      if (discontinued && replacedBy != null) 'replacedBy': replacedBy,
    };
    final unset = {
      if (!discontinued) 'isDiscontinued': '',
      if (!discontinued) 'discontinuedAt': '',
      if (!discontinued || replacedBy == null) 'replacedBy': '',
    };
    final result =
        await db.collection(packageCollection).updateOne(_selectByName(name), {
      if (set.isNotEmpty) r'$set': set,
      if (unset.isNotEmpty) r'$unset': unset,
    });
    _checkWrite(result, 'change discontinued state');
  }

  @override
  Future<UnpubQueryResult> queryPackages({
    required size,
    required page,
    required sort,
    keyword,
    uploader,
    dependency,
    includeDiscontinued = true,
  }) {
    var selector =
        where.sortBy(sort, descending: true).limit(size).skip(page * size);

    if (keyword != null) {
      selector =
          selector.match('name', RegExp.escape(keyword), caseInsensitive: true);
    }
    if (uploader != null) {
      selector = selector.eq('uploaders', uploader);
    }
    if (!includeDiscontinued) {
      selector = selector.ne('isDiscontinued', true);
    }
    if (dependency != null) {
      selector = selector.raw({
        'versions': {
          r'$elemMatch': {
            'pubspec.dependencies.$dependency': {r'$exists': true}
          }
        }
      });
    }

    return _queryPackagesBySelector(selector);
  }

  /// Pings the server.
  @override
  Future<void> checkHealth() async {
    await db.pingCommand();
  }
}
