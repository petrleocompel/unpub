import 'package:logging/logging.dart';

import '../config/config.dart';
import '../logging.dart';
import '../store/account_store.dart';
import '../store/audit_store.dart';
import 'accounts.dart';
import 'authenticator.dart';
import 'password_hasher.dart';

final _log = Logger('unpub.accounts');

/// Who is making a change, for the audit trail.
class AuditContext {
  /// The email of whoever acts, or `system`.
  final String actor;
  final String? ip;

  /// How the actor proved who it is, one of [AuditActorKind].
  final String kind;

  /// The prefix of the API token that acts, if one does.
  final String? token;

  const AuditContext(this.actor,
      {this.ip, this.kind = AuditActorKind.system, this.token});

  /// [principal] acting from [ip].
  factory AuditContext.of(Principal principal, {String? ip}) =>
      AuditContext(principal.email,
          ip: ip,
          kind: principal.credentialKind.name,
          token: principal.tokenPrefix);

  /// The server itself, or an operator at the command line.
  static const system = AuditContext('system');

  /// The event of [action] by this actor.
  AuditEvent event(
    String action, {
    String? package,
    String? version,
    String? target,
    Map<String, Object?> details = const {},
  }) =>
      AuditEvent(
        actor: actor,
        actorKind: kind,
        token: token,
        ip: ip,
        action: action,
        package: package,
        version: version,
        target: target,
        details: details,
      );
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

/// What [AccountService.updateUser] was asked to change.
class _UserChange {
  final String? displayName;
  final Role? role;
  final bool? disabled;
  final AuditContext by;

  const _UserChange(this.displayName, this.role, this.disabled, this.by);
}

/// How often [AccountService.updateUser] runs after finding the user changed.
const _updateAttempts = 3;

/// The account rules, shared by the HTTP API and the command line.
class AccountService {
  final AccountStore store;
  final AuditStore audit;
  final PasswordHasher hasher;
  final DateTime Function() clock;

  /// Called right before a write of the role or disabled state of a user, so
  /// after any change of the admin set, to let tests stall or fail there.
  final Future<void> Function()? beforeAdminUserWrite;

  /// Called after the user was read and before anything is written, on every
  /// attempt, to let tests make what was read stale.
  final Future<void> Function()? afterAdminClassified;

  AccountService(
    this.store, {
    this.audit = const NullAuditStore(),
    this.hasher = const PasswordHasher(),
    this.clock = DateTime.now,
    this.beforeAdminUserWrite,
    this.afterAdminClassified,
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
    if (user.isEnabledAdmin) {
      await _translatingContention(() => _recordEnabledAdmin(user.id));
    }
    await audit.recordSafely(by.event('user.created',
        target: user.email, details: {'role': role.name, ...auditDetails}));
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
  /// every change that affects the set writes it first and the user second,
  /// and the user only if it still has the role and disabled state this
  /// decision was based on. Otherwise the whole operation runs again on what
  /// the user is now.
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
    final change = _UserChange(newName, role, disabled, by);
    for (var attempt = 0; attempt < _updateAttempts; attempt++) {
      final current = await requireUserById(user.id);
      await afterAdminClassified?.call();
      final updated =
          await _translatingContention(() => _updateOnce(current, change));
      if (updated != null) return updated;
    }
    throw const AccountException.conflict('the user keeps changing, try again');
  }

  /// Runs [action], answering a retried admin set change that kept colliding
  /// with a 409 conflict, as the caller can simply try again.
  Future<T> _translatingContention<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on AdminSetContentionException catch (error) {
      _log.info('admin set contention: $error');
      throw const AccountException.conflict(
          'the admin set keeps changing, try again');
    }
  }

  /// One attempt of [updateUser], or null if [current] turned out to be stale.
  Future<User?> _updateOnce(User current, _UserChange change) {
    final staysAdmin = (change.role ?? current.role) == Role.admin &&
        !(change.disabled ?? current.disabled);
    if (current.isEnabledAdmin && !staysAdmin) {
      return _removeEnabledAdmin(current, change);
    }
    if (!current.isEnabledAdmin && staysAdmin) {
      return _addEnabledAdmin(current, change);
    }
    return _applyChanges(current, change);
  }

  Future<User?> _removeEnabledAdmin(User current, _UserChange change) async {
    final operation = generateSecret();
    final bool claimed;
    try {
      claimed = await _claimAdminRemoval(current.id, operation);
    } catch (_) {
      await _reconcileAfterFailure(abandoned: operation);
      rethrow;
    }
    if (!claimed) {
      final latest = await requireUserById(current.id);
      if (!latest.isEnabledAdmin) return null;
      if (await store.isAdminRemovalMarked(current.id)) {
        throw const AccountException.adminChangeInProgress();
      }
      throw const AccountException.lastAdmin();
    }
    try {
      final updated = await _applyChanges(current, change);
      await store.finishAdminRemoval(current.id, operation);
      return updated;
    } catch (_) {
      await _reconcileAfterFailure(abandoned: operation);
      rethrow;
    }
  }

  /// Takes the user out of the admin set. The set can be behind the `users`
  /// collection after a crash, so it is rebuilt before refusing.
  Future<bool> _claimAdminRemoval(String userId, String operation) async {
    if (await store.takeFromAdminSet(userId, clock(), operation: operation)) {
      return true;
    }
    await store.reconcileAdminSet(clock());
    return store.takeFromAdminSet(userId, clock(), operation: operation);
  }

  Future<User?> _addEnabledAdmin(User current, _UserChange change) async {
    if (!await _reserveAdminAddition(current.id)) {
      throw const AccountException.adminChangeInProgress();
    }
    try {
      final updated = await _applyChanges(current, change);
      if (updated == null) {
        final latest = await store.findUserById(current.id);
        if (latest == null || !latest.isEnabledAdmin) {
          await store.dropFromAdminSet(current.id);
        }
      }
      return updated;
    } catch (_) {
      await _reconcileAfterFailure();
      rethrow;
    }
  }

  /// Puts the user in the admin set, unless a removal is under way. A marker
  /// left by a process that died after writing the user only goes away in a
  /// rebuild, so one runs before refusing.
  Future<bool> _reserveAdminAddition(String userId) async {
    if (await store.addToAdminSet(userId)) return true;
    await store.reconcileAdminSet(clock());
    return store.addToAdminSet(userId);
  }

  /// Adds a user who was just created as an administrator to the set.
  ///
  /// Afterwards the user is read again, as a demotion cannot see someone who
  /// is not in the set yet and could have run in between. A created user has
  /// no id to put in the set beforehand.
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

  /// Writes what differs from [current], or returns null if a change of the
  /// role or disabled state found the user no longer as in [current].
  Future<User?> _applyChanges(User current, _UserChange change) async {
    final _UserChange(:displayName, :role, :disabled) = change;
    final changes = <String, Object?>{
      if (displayName != null && displayName != current.displayName)
        'displayName': displayName,
      if (role != null && role != current.role) 'role': role.name,
      if (disabled != null && disabled != current.disabled)
        'disabled': disabled,
    };
    if (changes.isEmpty) return current;

    final affectsAdmins =
        changes.containsKey('role') || changes.containsKey('disabled');
    if (affectsAdmins) await beforeAdminUserWrite?.call();
    final written = await store.updateUser(
      current.id,
      clock(),
      displayName: changes.containsKey('displayName') ? displayName : null,
      role: changes.containsKey('role') ? role : null,
      disabled: changes.containsKey('disabled') ? disabled : null,
      expected: affectsAdmins
          ? (role: current.role, disabled: current.disabled)
          : null,
    );
    if (!written) return null;

    if (disabled == true) await store.deleteSessionsOfUser(current.id);
    final by = change.by;
    if (changes.containsKey('displayName')) {
      await audit.recordSafely(by.event('user.updated',
          target: current.email, details: {'displayName': displayName}));
    }
    if (changes.containsKey('role')) {
      await audit.recordSafely(by.event('user.role_changed',
          target: current.email,
          details: {'from': current.role.name, 'to': role!.name}));
    }
    if (changes.containsKey('disabled')) {
      await audit.recordSafely(by.event(
          disabled! ? 'user.disabled' : 'user.enabled',
          target: current.email));
    }
    return requireUserById(current.id);
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
    await audit.recordSafely(by.event('user.password_set', target: user.email));
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
        actorKind: AuditActorKind.anonymous,
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
      actorKind: AuditActorKind.password,
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
    await audit.recordSafely(by.event(
      'token.created',
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
    await audit.recordSafely(by.event(
      'token.revoked',
      target: 'token:${token.prefix}',
      details: {'name': token.name, 'ownerId': token.userId},
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
