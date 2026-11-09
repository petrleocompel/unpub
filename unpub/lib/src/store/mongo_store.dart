import 'package:intl/intl.dart';
import 'package:logging/logging.dart';
import 'package:mongo_dart/mongo_dart.dart';
import 'package:unpub/src/models.dart';

import 'meta_store.dart';
import 'mongo_indexes.dart';

final packageCollection = 'packages';
final statsCollection = 'stats';
final versionStatsCollection = 'version_stats';
final uploadReservationsCollection = 'upload_reservations';

const _duplicateKeyCode = 11000;

/// How long a reservation outlives a server that died while holding it. The
/// archive write and metadata update it covers take far less than this.
const _uploadReservationTtl = Duration(minutes: 15);

final _log = Logger('unpub.mongo');

class MongoStore extends MetaStore {
  Db db;

  MongoStore(this.db);

  /// Creates the indexes the store relies on, which is safe to repeat.
  ///
  /// The unique index keeps two concurrent first downloads of a version from
  /// creating two counter documents.
  Future<void> ensureIndexes() async {
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
    if (await packages.findOne(_selectByName(name).fields(['_id'])) != null) {
      // The condition keeps two concurrent publishes of one version from both
      // being added.
      final result = await packages.updateOne(
          where.eq('name', name).ne('versions.version', version.version),
          modify
              .push('versions', version.toJson())
              .set('updatedAt', version.createdAt));
      _checkWrite(result, 'add version');
      return result.nModified == 1;
    }
    await packages.update(
        _selectByName(name),
        modify
            .push('versions', version.toJson())
            // Only a new package gets its first uploader. An administrator
            // publishing to someone else's package must not join it.
            .setOnInsert('uploaders', [version.uploader])
            .setOnInsert('createdAt', version.createdAt)
            .setOnInsert('private', true)
            .setOnInsert('download', 0)
            .set('updatedAt', version.createdAt),
        upsert: true);
    return true;
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
      'expiresAt': now.add(_uploadReservationTtl),
    });
    if (result.writeError?.code == _duplicateKeyCode) return null;
    _checkWrite(result, 'reserve upload');
    return reservation;
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
