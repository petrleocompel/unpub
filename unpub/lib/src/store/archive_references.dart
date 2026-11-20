import 'package:mongo_dart/mongo_dart.dart';

import 'mongo_store.dart';
import 'object_locks.dart';
import 'upstream_cache_store.dart';

/// Says which stored objects something still points to.
abstract class ArchiveReferences {
  /// The locks shared with whatever writes the references, which reclamation
  /// has to hold while it decides that an object has none.
  ObjectLocks get objectLocks;

  /// Every digest a version or an upstream archive record names.
  Future<Set<String>> digests();

  /// Whether a version or an upstream archive record names [digest].
  Future<bool> isReferenced(String digest);
}

/// Reads the digests in the `packages` and `upstream_archives` collections.
class MongoArchiveReferences implements ArchiveReferences {
  final Db db;

  const MongoArchiveReferences(this.db);

  @override
  ObjectLocks get objectLocks => MongoObjectLocks(db);

  DbCollection get _packages => db.collection(packageCollection);
  DbCollection get _archives => db.collection(upstreamArchivesCollection);

  @override
  Future<Set<String>> digests() async {
    final digests = <String>{};
    await for (final package
        in _packages.find(where.fields(['versions.sha256']))) {
      for (final version in package['versions'] as List? ?? const []) {
        final digest = version['sha256'];
        if (digest is String) digests.add(digest);
      }
    }
    await for (final record in _archives.find(where.fields(['sha256']))) {
      final digest = record['sha256'];
      if (digest is String) digests.add(digest);
    }
    return digests;
  }

  @override
  Future<bool> isReferenced(String digest) async =>
      await _packages
              .findOne(where.eq('versions.sha256', digest).fields(['_id'])) !=
          null ||
      await _archives.findOne(where.eq('sha256', digest).fields(['_id'])) !=
          null;
}
