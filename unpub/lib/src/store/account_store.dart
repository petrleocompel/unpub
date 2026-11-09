import 'package:logging/logging.dart';
import 'package:mongo_dart/mongo_dart.dart';

import '../auth/accounts.dart';
import 'mongo_indexes.dart';

final userCollection = 'users';
final tokenCollection = 'tokens';
final sessionCollection = 'sessions';
final adminSetCollection = 'admin_set';

final _log = Logger('unpub.accounts');

const _adminSetId = 'enabled_admins';

/// How long a removal from the admin set counts as still running.
///
/// [AccountStore.reconcileAdminSet] leaves a user out of the set for this long
/// after a removal started, so that it cannot put back someone whose demotion
/// is still on its way to the `users` collection. After that the process is
/// taken to have died and the user, still an enabled admin, is put back.
const adminRemovalGrace = Duration(minutes: 5);

/// How often a change of the admin set is retried after losing a race.
const _adminSetAttempts = 5;

const _duplicateKeyCode = 11000;

/// How often a token's `lastUsedAt` is written at most.
const lastUsedInterval = Duration(minutes: 1);

/// Raised when a user with the same email already exists.
class DuplicateEmailException implements Exception {
  const DuplicateEmailException();
}

/// Raised when MongoDB refuses a change of the admin set.
class AdminSetException implements Exception {
  final int? code;
  final String? message;

  const AdminSetException(this.code, this.message);

  @override
  String toString() => 'cannot change the admin set: $message (code $code)';
}

/// The fields of a new user.
class NewUser {
  final String email;
  final String displayName;
  final String? passwordHash;
  final Role role;

  const NewUser({
    required this.email,
    required this.displayName,
    required this.passwordHash,
    required this.role,
  });
}

/// The fields of a new token.
class NewToken {
  final String userId;
  final String name;
  final String prefix;
  final String hash;
  final Set<Scope> scopes;
  final DateTime? expiresAt;

  const NewToken({
    required this.userId,
    required this.name,
    required this.prefix,
    required this.hash,
    required this.scopes,
    required this.expiresAt,
  });
}

/// Users, tokens and sessions in MongoDB.
class AccountStore {
  final Db db;

  AccountStore(this.db);

  DbCollection get _users => db.collection(userCollection);
  DbCollection get _tokens => db.collection(tokenCollection);
  DbCollection get _sessions => db.collection(sessionCollection);
  DbCollection get _adminSet => db.collection(adminSetCollection);

  /// Creates the indexes the collections rely on. Safe to call repeatedly.
  Future<void> ensureIndexes() async {
    await createIndexes(db, userCollection, [
      {
        'key': {'email': 1},
        'name': 'email_unique',
        'unique': true,
      },
    ]);
    await createIndexes(db, tokenCollection, [
      {
        'key': {'hash': 1},
        'name': 'hash_unique',
        'unique': true,
      },
      {
        'key': {'userId': 1},
        'name': 'userId',
      },
    ]);
    await createIndexes(db, sessionCollection, [
      {
        'key': {'expiresAt': 1},
        'name': 'expiresAt_ttl',
        'expireAfterSeconds': 0,
      },
      {
        'key': {'userId': 1},
        'name': 'userId',
      },
    ]);
  }

  static ObjectId? _objectId(String id) {
    try {
      return ObjectId.fromHexString(id);
    } catch (_) {
      return null;
    }
  }

  static User _userFromDocument(Map<String, dynamic> doc) => User(
        id: (doc['_id'] as ObjectId).oid,
        email: doc['email'] as String,
        displayName: doc['displayName'] as String? ?? '',
        passwordHash: doc['passwordHash'] as String?,
        role: Role.tryParse(doc['role']) ?? Role.reader,
        disabled: doc['disabled'] as bool? ?? false,
        createdAt: doc['createdAt'] as DateTime,
        updatedAt: doc['updatedAt'] as DateTime,
        lastLoginAt: doc['lastLoginAt'] as DateTime?,
      );

  static ApiToken _tokenFromDocument(Map<String, dynamic> doc) => ApiToken(
        id: (doc['_id'] as ObjectId).oid,
        userId: (doc['userId'] as ObjectId).oid,
        name: doc['name'] as String,
        prefix: doc['prefix'] as String,
        hash: doc['hash'] as String,
        scopes: {
          for (final name in doc['scopes'] as List)
            if (Scope.tryParse(name) case final scope?) scope,
        },
        expiresAt: doc['expiresAt'] as DateTime?,
        lastUsedAt: doc['lastUsedAt'] as DateTime?,
        createdAt: doc['createdAt'] as DateTime,
        revokedAt: doc['revokedAt'] as DateTime?,
      );

  static Session _sessionFromDocument(Map<String, dynamic> doc) => Session(
        id: doc['_id'] as String,
        userId: (doc['userId'] as ObjectId).oid,
        createdAt: doc['createdAt'] as DateTime,
        expiresAt: doc['expiresAt'] as DateTime,
        csrfToken: doc['csrfToken'] as String,
      );

  Future<bool> hasNoUsers() async => await _users.findOne() == null;

  /// Stores a new user, or throws [DuplicateEmailException].
  Future<User> insertUser(NewUser user, DateTime now) async {
    final document = <String, dynamic>{
      '_id': ObjectId(),
      'email': user.email,
      'displayName': user.displayName,
      'passwordHash': user.passwordHash,
      'role': user.role.name,
      'disabled': false,
      'createdAt': now,
      'updatedAt': now,
      'lastLoginAt': null,
    };
    final result = await _users.insertOne(document);
    if (result.hasWriteErrors) {
      if (result.writeError?.code == _duplicateKeyCode) {
        throw const DuplicateEmailException();
      }
      throw StateError('cannot store user: ${result.writeError?.errmsg}');
    }
    return _userFromDocument(document);
  }

  Future<User?> findUserById(String id) async {
    final objectId = _objectId(id);
    if (objectId == null) return null;
    final doc = await _users.findOne(where.id(objectId));
    return doc == null ? null : _userFromDocument(doc);
  }

  Future<User?> findUserByEmail(String email) async {
    final doc = await _users.findOne(where.eq('email', email));
    return doc == null ? null : _userFromDocument(doc);
  }

  Future<List<User>> listUsers() =>
      _users.find(where.sortBy('email')).map(_userFromDocument).toList();

  SelectorBuilder get _enabledAdmins =>
      where.eq('role', Role.admin.name).ne('disabled', true);

  /// One atomic change of the admin set, or null when [query] matched nothing.
  ///
  /// `findAndModify` reports a failed command in its reply rather than by
  /// throwing, and a failure must not read as "matched nothing", which callers
  /// take to mean this is the last administrator.
  Future<Map<String, dynamic>?> _modifyAdminSet(
    Map<String, Object?> query,
    Map<String, Object?> update, {
    bool upsert = false,
  }) async {
    final result = await _adminSet.modernFindAndModify(
      query: query,
      update: update,
      upsert: upsert,
      returnNew: true,
    );
    if (result.failure) {
      throw AdminSetException(result.code, result.errmsg);
    }
    return result.value;
  }

  /// Takes [userId] out of the set of enabled administrators, unless that
  /// would empty it, and marks the removal as under way for [operation].
  ///
  /// This one atomic update is what upholds the last-administrator rule, so a
  /// caller that is suspended afterwards cannot break it: nobody else can take
  /// the last remaining id. Returns false if the set does not allow it.
  Future<bool> takeFromAdminSet(
    String userId,
    DateTime now, {
    String? operation,
  }) async {
    final id = operation ?? generateSecret();
    final remaining = await _modifyAdminSet(
      {
        '_id': _adminSetId,
        'userIds': userId,
        'userIds.1': {r'$exists': true},
      },
      {
        r'$pull': {'userIds': userId},
        r'$set': {
          'removing.$userId': {'op': id, 'at': now},
        },
        r'$inc': {'version': 1},
      },
    );
    if (remaining == null) return false;

    // An id left in the set by something outside this class, or by a promotion
    // that has not written the user yet, must not count as the administrator
    // who remains.
    final others = [
      for (final id in remaining['userIds'] as List)
        if (_objectId(id as String) case final objectId?) objectId,
    ];
    final another = await _users.findOne(_enabledAdmins.oneFrom('_id', others));
    if (another != null) return true;

    await _modifyAdminSet(
      {'_id': _adminSetId, 'removing.$userId.op': id},
      {
        r'$addToSet': {'userIds': userId},
        r'$unset': {'removing.$userId': ''},
        r'$inc': {'version': 1},
      },
    );
    return false;
  }

  /// Whether a removal of [userId] from the set is marked as under way.
  Future<bool> isAdminRemovalMarked(String userId) async {
    final current = await _adminSet.findOne(where.eq('_id', _adminSetId));
    return _hasMarker(current, userId);
  }

  static bool _hasMarker(Map<String, dynamic>? set, String userId) =>
      switch (set?['removing']) {
        final Map<String, dynamic> removing => removing.containsKey(userId),
        _ => false,
      };

  /// Adds [userId] to the set of enabled administrators.
  ///
  /// Returns false, changing nothing, while the removal of this user is under
  /// way: the markers of other operations are not this one's to clear.
  Future<bool> addToAdminSet(String userId) async {
    for (var attempt = 1;; attempt++) {
      try {
        await _modifyAdminSet(
          {
            '_id': _adminSetId,
            'removing.$userId': {r'$exists': false},
          },
          {
            r'$addToSet': {'userIds': userId},
            r'$inc': {'version': 1},
          },
          upsert: true,
        );
        return true;
      } on AdminSetException catch (error) {
        // The upsert also collides when the document exists but the filter
        // did not match it, and when two first inserts race.
        if (error.code != _duplicateKeyCode || attempt == _adminSetAttempts) {
          rethrow;
        }
        if (await isAdminRemovalMarked(userId)) return false;
      }
    }
  }

  /// Removes [userId], who is no longer an enabled administrator, from the
  /// set. Never refused: this id does not stand for an administrator.
  Future<void> dropFromAdminSet(String userId) async {
    await _modifyAdminSet(
      {'_id': _adminSetId},
      {
        r'$pull': {'userIds': userId},
        r'$inc': {'version': 1},
      },
    );
  }

  /// Forgets the removal of [userId] marked by [operation], and does nothing
  /// if another operation holds the marker now. The record ages out by itself,
  /// so a failure here must not replace the outcome of the removal.
  Future<void> finishAdminRemoval(String userId, String operation) async {
    try {
      await _modifyAdminSet(
        {'_id': _adminSetId, 'removing.$userId.op': operation},
        {
          r'$unset': {'removing.$userId': ''},
          r'$inc': {'version': 1},
        },
      );
    } catch (error) {
      _log.warning('cannot finish the removal of an administrator', error);
    }
  }

  /// Rebuilds the admin set from the `users` collection.
  ///
  /// Users with a removal started in the last [adminRemovalGrace] stay out,
  /// except the one marked by [abandoned], an operation the caller knows has
  /// failed. Every change of the set increases `version`, and the set is only
  /// replaced at the version it was read at, so that a concurrent change is
  /// not undone.
  ///
  /// [beforeReplace] runs after the reads, to let tests change the set in
  /// between.
  Future<void> reconcileAdminSet(
    DateTime now, {
    String? abandoned,
    Future<void> Function()? beforeReplace,
  }) async {
    for (var attempt = 1;; attempt++) {
      final current = await _adminSet.findOne(where.eq('_id', _adminSetId));
      final version = current?['version'] as int?;
      final enabled = await _users
          .find(_enabledAdmins)
          .map((doc) => (doc['_id'] as ObjectId).oid)
          .toSet();
      final removing = <String, Object?>{
        if (current?['removing'] case final Map<String, dynamic> started)
          for (final MapEntry(:key, :value) in started.entries)
            if (value case {'op': final String op, 'at': final DateTime at}
                when op != abandoned &&
                    enabled.contains(key) &&
                    now.difference(at) < adminRemovalGrace)
              key: value,
      };
      await beforeReplace?.call();

      try {
        final replaced = await _modifyAdminSet(
          {'_id': _adminSetId, 'version': version},
          {
            '_id': _adminSetId,
            'userIds': enabled.difference(removing.keys.toSet()).toList()
              ..sort(),
            'removing': removing,
            'version': (version ?? 0) + 1,
          },
          upsert: true,
        );
        if (replaced != null) return;
      } on AdminSetException catch (error) {
        // The upsert of a version that changed meanwhile.
        if (error.code != _duplicateKeyCode) rethrow;
      }
      if (attempt == _adminSetAttempts) {
        throw StateError('the admin set keeps changing, cannot rebuild it');
      }
    }
  }

  /// Writes the given fields of the user.
  ///
  /// With [expected], only if the user still has that role and disabled state,
  /// matched the way [_userFromDocument] reads them. Returns false if it did
  /// not, or if there is no such user.
  Future<bool> updateUser(
    String id,
    DateTime now, {
    String? displayName,
    Role? role,
    bool? disabled,
    ({Role role, bool disabled})? expected,
  }) async {
    var update = modify.set('updatedAt', now);
    if (displayName != null) update = update.set('displayName', displayName);
    if (role != null) update = update.set('role', role.name);
    if (disabled != null) update = update.set('disabled', disabled);
    final result = await _users.updateOne(
      {
        '_id': _objectId(id)!,
        if (expected != null) ...{
          'role': expected.role == Role.reader
              ? {
                  r'$nin': [
                    for (final other in Role.values)
                      if (other != Role.reader) other.name,
                  ],
                }
              : expected.role.name,
          'disabled': expected.disabled ? true : {r'$ne': true},
        },
      },
      update,
    );
    if (result.hasWriteErrors || !result.operationSucceeded) {
      throw StateError('cannot update user: '
          '${result.writeError?.errmsg ?? result.errmsg}');
    }
    return result.nMatched == 1;
  }

  Future<void> setPasswordHash(String id, String hash, DateTime now) async {
    await _users.updateOne(where.id(_objectId(id)!),
        modify.set('passwordHash', hash).set('updatedAt', now));
  }

  Future<void> setLastLogin(String id, DateTime now) async {
    await _users.updateOne(
        where.id(_objectId(id)!), modify.set('lastLoginAt', now));
  }

  Future<ApiToken> insertToken(NewToken token, DateTime now) async {
    final document = <String, dynamic>{
      '_id': ObjectId(),
      'userId': _objectId(token.userId),
      'name': token.name,
      'prefix': token.prefix,
      'hash': token.hash,
      'scopes': [for (final scope in token.scopes) scope.name],
      'expiresAt': token.expiresAt,
      'lastUsedAt': null,
      'createdAt': now,
      'revokedAt': null,
    };
    final result = await _tokens.insertOne(document);
    if (result.hasWriteErrors) {
      throw StateError('cannot store token: ${result.writeError?.errmsg}');
    }
    return _tokenFromDocument(document);
  }

  Future<ApiToken?> findTokenByHash(String hash) async {
    final doc = await _tokens.findOne(where.eq('hash', hash));
    return doc == null ? null : _tokenFromDocument(doc);
  }

  Future<ApiToken?> findTokenById(String id) async {
    final objectId = _objectId(id);
    if (objectId == null) return null;
    final doc = await _tokens.findOne(where.id(objectId));
    return doc == null ? null : _tokenFromDocument(doc);
  }

  Future<List<ApiToken>> listTokens(String userId) => _tokens
      .find(where
          .eq('userId', _objectId(userId))
          .sortBy('createdAt', descending: true))
      .map(_tokenFromDocument)
      .toList();

  /// Records a use of the token, unless one was recorded in the last
  /// [lastUsedInterval]. The condition makes this hold across processes.
  Future<void> touchToken(String id, DateTime now) async {
    await _tokens.updateOne(
      {
        '_id': _objectId(id),
        r'$or': [
          {'lastUsedAt': null},
          {
            'lastUsedAt': {r'$lte': now.subtract(lastUsedInterval)},
          },
        ],
      },
      modify.set('lastUsedAt', now),
    );
  }

  /// Revokes the token. Returns false if it had been revoked already.
  Future<bool> revokeToken(String id, DateTime now) async {
    final result = await _tokens.updateOne(
      {'_id': _objectId(id), 'revokedAt': null},
      modify.set('revokedAt', now),
    );
    return result.nModified == 1;
  }

  Future<void> insertSession(Session session) async {
    final result = await _sessions.insertOne({
      '_id': session.id,
      'userId': _objectId(session.userId),
      'createdAt': session.createdAt,
      'expiresAt': session.expiresAt,
      'csrfToken': session.csrfToken,
    });
    if (result.hasWriteErrors) {
      throw StateError('cannot store session: ${result.writeError?.errmsg}');
    }
  }

  Future<Session?> findSession(String id) async {
    final doc = await _sessions.findOne(where.eq('_id', id));
    return doc == null ? null : _sessionFromDocument(doc);
  }

  Future<void> deleteSession(String id) async {
    await _sessions.deleteOne(where.eq('_id', id));
  }

  /// Ends the sessions of the user, except the one with id [exceptId].
  Future<void> deleteSessionsOfUser(String userId, {String? exceptId}) async {
    var selector = where.eq('userId', _objectId(userId));
    if (exceptId != null) selector = selector.ne('_id', exceptId);
    await _sessions.deleteMany(selector);
  }
}
