import 'package:mongo_dart/mongo_dart.dart';

import '../auth/accounts.dart';
import 'mongo_indexes.dart';

final userCollection = 'users';
final tokenCollection = 'tokens';
final sessionCollection = 'sessions';

const _duplicateKeyCode = 11000;

/// How often a token's `lastUsedAt` is written at most.
const lastUsedInterval = Duration(minutes: 1);

/// Raised when a user with the same email already exists.
class DuplicateEmailException implements Exception {
  const DuplicateEmailException();
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

  Future<int> countEnabledAdmins() =>
      _users.count(where.eq('role', Role.admin.name).ne('disabled', true));

  Future<void> updateUser(
    String id,
    DateTime now, {
    String? displayName,
    Role? role,
    bool? disabled,
  }) async {
    var update = modify.set('updatedAt', now);
    if (displayName != null) update = update.set('displayName', displayName);
    if (role != null) update = update.set('role', role.name);
    if (disabled != null) update = update.set('disabled', disabled);
    await _users.updateOne(where.id(_objectId(id)!), update);
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
