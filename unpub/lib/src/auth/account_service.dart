import 'package:logging/logging.dart';

import '../config/config.dart';
import '../logging.dart';
import '../store/account_store.dart';
import '../store/audit_store.dart';
import 'accounts.dart';
import 'password_hasher.dart';

final _log = Logger('unpub.accounts');

/// Who is making a change, for the audit trail.
class AuditContext {
  final String actor;
  final String? ip;

  const AuditContext(this.actor, {this.ip});

  /// The server itself, or an operator at the command line.
  static const system = AuditContext('system');
}

/// A session created by a successful login.
class LoginResult {
  final User user;
  final Session session;

  /// The cookie value. Only its hash is stored.
  final String cookieValue;

  const LoginResult(this.user, this.session, this.cookieValue);
}

/// A freshly created token together with its secret, available only now.
class CreatedToken {
  final ApiToken token;
  final String secret;

  const CreatedToken(this.token, this.secret);
}

/// The account rules, shared by the HTTP API and the command line.
class AccountService {
  final AccountStore store;
  final AuditStore audit;
  final PasswordHasher hasher;
  final DateTime Function() clock;

  /// Called after the admin set changed and before the user is written, to
  /// let tests stall or fail between the two.
  final Future<void> Function()? beforeAdminUserWrite;

  AccountService(
    this.store, {
    this.audit = const NullAuditStore(),
    this.hasher = const PasswordHasher(),
    this.clock = DateTime.now,
    this.beforeAdminUserWrite,
  });

  /// Compared against when a login has no hash to check, to take the same
  /// time.
  late final Future<String> _dummyHash = hasher.hash(generateSecret());

  static String _checkedEmail(String email) {
    final normalized = normalizeEmail(email);
    if (!isValidEmail(normalized)) {
      throw const AccountException.invalid('email is invalid');
    }
    return normalized;
  }

  static void _checkPassword(String password) {
    final problem = passwordProblem(password);
    if (problem != null) throw AccountException.invalid(problem);
  }

  /// Creates a user. Without a [password] it is a placeholder that cannot log
  /// in until one is set.
  Future<User> createUser({
    required String email,
    required Role role,
    String? displayName,
    String? password,
    AuditContext by = AuditContext.system,
    Map<String, Object?> auditDetails = const {},
  }) async {
    final normalized = _checkedEmail(email);
    if (password != null) _checkPassword(password);
    final name = (displayName ?? '').trim();
    final User user;
    try {
      user = await store.insertUser(
        NewUser(
          email: normalized,
          displayName: name.isEmpty ? normalized.split('@').first : name,
          passwordHash: password == null ? null : await hasher.hash(password),
          role: role,
        ),
        clock(),
      );
    } on DuplicateEmailException {
      throw AccountException.conflict('user $normalized already exists');
    }
    if (user.isEnabledAdmin) await _recordEnabledAdmin(user.id);
    await audit.recordSafely(AuditEvent(
      actor: by.actor,
      ip: by.ip,
      action: 'user.created',
      target: user.email,
      details: {'role': role.name, ...auditDetails},
    ));
    return user;
  }

  Future<User> requireUserById(String id) async {
    final user = await store.findUserById(id);
    if (user == null) throw const AccountException.notFound('no such user');
    return user;
  }

  Future<User> requireUserByEmail(String email) async {
    final normalized = normalizeEmail(email);
    final user = await store.findUserByEmail(normalized);
    if (user == null) {
      throw AccountException.notFound('no user with email $normalized');
    }
    return user;
  }

  /// Applies the changes that differ from the current state of the user.
  ///
  /// Refuses to leave the registry without an enabled administrator. MongoDB
  /// has no transaction across the `users` collection and the admin set, so
  /// the writes come in the order that keeps the rule when a process stalls or
  /// dies between them: the set first when an administrator goes away, the
  /// user first when one is added.
  Future<User> updateUser(
    User user, {
    String? displayName,
    Role? role,
    bool? disabled,
    AuditContext by = AuditContext.system,
  }) async {
    final newName = displayName?.trim();
    if (newName != null && newName.isEmpty) {
      throw const AccountException.invalid('displayName must not be empty');
    }
    final current = await requireUserById(user.id);
    final staysAdmin =
        (role ?? current.role) == Role.admin && !(disabled ?? current.disabled);

    if (current.isEnabledAdmin && !staysAdmin) {
      return _removeEnabledAdmin(current,
          displayName: newName, role: role, disabled: disabled, by: by);
    }
    final updated = await _applyChanges(current,
        displayName: newName, role: role, disabled: disabled, by: by);
    if (!current.isEnabledAdmin && staysAdmin) {
      await _recordEnabledAdmin(updated.id);
    }
    return updated;
  }

  Future<User> _removeEnabledAdmin(
    User user, {
    required String? displayName,
    required Role? role,
    required bool? disabled,
    required AuditContext by,
  }) async {
    final bool claimed;
    try {
      claimed = await _claimAdminRemoval(user.id);
    } catch (_) {
      await _reconcileAfterFailure(abandoned: user.id);
      rethrow;
    }
    if (!claimed) {
      final latest = await requireUserById(user.id);
      if (latest.isEnabledAdmin) throw const AccountException.lastAdmin();
      // Another request removed this administrator first.
      return _applyChanges(latest,
          displayName: displayName, role: role, disabled: disabled, by: by);
    }
    try {
      await beforeAdminUserWrite?.call();
      final updated = await _applyChanges(user,
          displayName: displayName, role: role, disabled: disabled, by: by);
      await store.finishAdminRemoval(user.id);
      return updated;
    } catch (_) {
      await _reconcileAfterFailure(abandoned: user.id);
      rethrow;
    }
  }

  /// Takes the user out of the admin set. The set can be behind the `users`
  /// collection after a crash, so it is rebuilt before refusing.
  Future<bool> _claimAdminRemoval(String userId) async {
    if (await store.takeFromAdminSet(userId, clock())) return true;
    await store.reconcileAdminSet(clock());
    return store.takeFromAdminSet(userId, clock());
  }

  /// Adds a user who has just become an enabled administrator to the set.
  ///
  /// Afterwards the user is read again, as a demotion cannot see someone who
  /// is not in the set yet and could have run in between.
  Future<void> _recordEnabledAdmin(String userId) async {
    try {
      await store.addToAdminSet(userId);
      final latest = await store.findUserById(userId);
      if (latest == null || !latest.isEnabledAdmin) {
        await store.dropFromAdminSet(userId);
      }
    } catch (_) {
      await _reconcileAfterFailure();
      rethrow;
    }
  }

  /// Brings the set back in line after one of its two writes failed. The
  /// original failure is what the caller needs to see, and the next start or
  /// `unpub admin` command repairs the set anyway.
  Future<void> _reconcileAfterFailure({String? abandoned}) async {
    try {
      await store.reconcileAdminSet(clock(), abandoned: abandoned);
    } catch (error) {
      _log.warning('cannot rebuild the admin set', error);
    }
  }

  Future<User> _applyChanges(
    User user, {
    required String? displayName,
    required Role? role,
    required bool? disabled,
    required AuditContext by,
  }) async {
    final changes = <String, Object?>{
      if (displayName != null && displayName != user.displayName)
        'displayName': displayName,
      if (role != null && role != user.role) 'role': role.name,
      if (disabled != null && disabled != user.disabled) 'disabled': disabled,
    };
    if (changes.isEmpty) return user;

    await store.updateUser(
      user.id,
      clock(),
      displayName: changes.containsKey('displayName') ? displayName : null,
      role: changes.containsKey('role') ? role : null,
      disabled: changes.containsKey('disabled') ? disabled : null,
    );
    if (disabled == true) await store.deleteSessionsOfUser(user.id);
    await audit.recordSafely(AuditEvent(
      actor: by.actor,
      ip: by.ip,
      action: 'user.updated',
      target: user.email,
      details: changes,
    ));
    return requireUserById(user.id);
  }

  /// Sets the password and ends the sessions of [user], except
  /// [keepSessionId], so that a stolen session does not outlive the change.
  Future<void> setPassword(
    User user,
    String password, {
    AuditContext by = AuditContext.system,
    String? keepSessionId,
  }) async {
    _checkPassword(password);
    await store.setPasswordHash(user.id, await hasher.hash(password), clock());
    await store.deleteSessionsOfUser(user.id, exceptId: keepSessionId);
    await audit.recordSafely(AuditEvent(
      actor: by.actor,
      ip: by.ip,
      action: 'user.password_set',
      target: user.email,
    ));
  }

  /// Verifies [password] against the stored hash of [user].
  ///
  /// Spends the same time when there is no hash to compare with.
  Future<bool> verifyPassword(User? user, String password) async {
    final hash = user?.passwordHash;
    if (hash == null) {
      await hasher.verify(password, await _dummyHash);
      return false;
    }
    return hasher.verify(password, hash);
  }

  /// Starts a session, or returns null if the credentials are not accepted.
  Future<LoginResult?> login({
    required String email,
    required String password,
    String? ip,
  }) async {
    final normalized = normalizeEmail(email);
    final user = await store.findUserByEmail(normalized);
    final matches = await verifyPassword(user, password);

    final String? failure;
    if (user == null) {
      failure = 'unknown_user';
    } else if (user.passwordHash == null) {
      failure = 'no_password';
    } else if (!matches) {
      failure = 'bad_password';
    } else if (user.disabled) {
      failure = 'disabled';
    } else {
      failure = null;
    }
    if (failure != null) {
      await audit.recordSafely(AuditEvent(
        actor: normalized,
        ip: ip,
        action: 'user.login_failed',
        target: normalized,
        details: {'reason': failure},
      ));
      return null;
    }

    final now = clock();
    final cookieValue = generateSecret();
    final session = Session(
      id: hashSecret(cookieValue),
      userId: user!.id,
      createdAt: now,
      expiresAt: now.add(sessionLifetime),
      csrfToken: generateSecret(),
    );
    await store.insertSession(session);
    await store.setLastLogin(user.id, now);
    await audit.recordSafely(AuditEvent(
      actor: user.email,
      ip: ip,
      action: 'user.login',
      target: user.email,
    ));
    return LoginResult(await requireUserById(user.id), session, cookieValue);
  }

  /// Ends the session with the cookie value [cookieValue], if it exists.
  Future<void> logout(String cookieValue) =>
      store.deleteSession(hashSecret(cookieValue));

  /// Creates a token for [user].
  ///
  /// Without [scopes] it gets every scope the role of the user allows.
  Future<CreatedToken> createToken(
    User user, {
    required String name,
    Set<Scope>? scopes,
    DateTime? expiresAt,
    AuditContext by = AuditContext.system,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > 100) {
      throw const AccountException.invalid(
          'name must have between 1 and 100 characters');
    }
    final allowed = scopesAllowedFor(user.role);
    final granted = scopes ?? allowed;
    if (granted.isEmpty) {
      throw const AccountException.invalid('at least one scope is required');
    }
    if (!allowed.containsAll(granted)) {
      throw AccountException.forbidden(
          'a ${user.role.name} cannot hold a token with these scopes');
    }
    final now = clock();
    if (expiresAt != null && !expiresAt.isAfter(now)) {
      throw const AccountException.invalid('expiry must be in the future');
    }

    final secret = generateSecret();
    final token = await store.insertToken(
      NewToken(
        userId: user.id,
        name: trimmed,
        prefix: secret.substring(0, 8),
        hash: hashSecret(secret),
        scopes: granted,
        expiresAt: expiresAt,
      ),
      now,
    );
    await audit.recordSafely(AuditEvent(
      actor: by.actor,
      ip: by.ip,
      action: 'token.created',
      target: 'token:${token.prefix}',
      details: {
        'user': user.email,
        'name': token.name,
        'scopes': [for (final scope in granted) scope.name],
      },
    ));
    return CreatedToken(token, secret);
  }

  /// Revokes [token]. Revoking it twice changes nothing and records nothing.
  Future<void> revokeToken(
    ApiToken token, {
    AuditContext by = AuditContext.system,
  }) async {
    if (!await store.revokeToken(token.id, clock())) return;
    await audit.recordSafely(AuditEvent(
      actor: by.actor,
      ip: by.ip,
      action: 'token.revoked',
      target: 'token:${token.prefix}',
      details: {'name': token.name},
    ));
  }

  /// Creates the first administrator from `auth.admin.*` on an empty
  /// `users` collection, and does nothing otherwise.
  Future<void> bootstrapAdmin(AdminBootstrapConfig? admin) async {
    if (!await store.hasNoUsers()) {
      if (admin != null) {
        _log.info('users already exist, ignoring auth.admin.email and '
            'auth.admin.password');
      }
      return;
    }
    if (admin == null) {
      _log.warning('there are no users, set auth.admin.email and '
          'auth.admin.password or run unpub admin create-user');
      return;
    }
    try {
      await createUser(
        email: admin.email,
        role: Role.admin,
        password: admin.password,
      );
    } on AccountException catch (error) {
      if (error.statusCode != 409) rethrow;
      // Another instance starting at the same time got there first.
      return;
    }
    _log.info(LogEvent('created administrator', {'email': admin.email}));
  }
}
