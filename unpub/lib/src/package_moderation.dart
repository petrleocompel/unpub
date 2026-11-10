import 'dart:io';

import 'package:collection/collection.dart' show IterableExtension;
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart' as shelf;

import 'app.dart';
import 'auth/accounts.dart';
import 'auth/authenticator.dart';
import 'logging.dart';
import 'models.dart';
import 'routes/route_support.dart';
import 'store/package_store.dart';
import 'validation.dart';

final _log = Logger('unpub.moderation');

/// How long deleting waits for the lock of an archive object that a publish or
/// reclamation holds, before leaving the object to reclamation.
const _objectLockTimeout = Duration(seconds: 30);

/// How often deleting a package starts over after a version was published
/// while it took the reservations.
const _deleteAttempts = 3;

/// A package change that was refused, with the HTTP status to report.
class ModerationException implements Exception {
  final int statusCode;
  final String message;

  const ModerationException(this.statusCode, this.message);

  const ModerationException.invalid(this.message)
      : statusCode = HttpStatus.badRequest;

  @override
  String toString() => message;
}

/// The rules for changing uploaders, retraction and the discontinued flag, and
/// for deleting versions and packages, shared by the pub API and the admin
/// pages. Every change is audited.
class PackageModeration {
  final App app;

  const PackageModeration(this.app);

  /// The package when [principal] may manage it.
  ///
  /// Only an administrator learns that a package does not exist.
  Future<UnpubPackage> _packageForChange(
      String name, Principal principal) async {
    final package = await app.metaStore.queryPackage(name);
    if (package == null && principal.canPublish && principal.isAdmin) {
      throw const ModerationException(HttpStatus.notFound, 'Not Found');
    }
    if (package == null || !principal.canChangePackage(package.uploaders)) {
      throw const ModerationException(HttpStatus.forbidden, 'no permission');
    }
    return package;
  }

  /// Adds [email], already normalized and valid, to the uploaders of [name].
  Future<String> addUploader(
      shelf.Request req, Principal principal, String name, String email) async {
    final package = await _packageForChange(name, principal);
    if (findEmail(package.uploaders, email) != null) {
      throw const ModerationException.invalid('email already exists');
    }
    await app.metaStore.addUploader(name, email);
    await app.audit(req, principal, 'uploader.added',
        package: name, details: {'email': email});
    return 'uploader added';
  }

  /// Removes [email], compared ignoring case, from the uploaders of [name].
  Future<String> removeUploader(
      shelf.Request req, Principal principal, String name, String email) async {
    final package = await _packageForChange(name, principal);
    final stored = findEmail(package.uploaders, email);
    if (stored == null) {
      throw const ModerationException.invalid('email not uploader');
    }
    await app.metaStore.removeUploader(name, stored);
    await app.audit(req, principal, 'uploader.removed',
        package: name, details: {'email': stored});
    return 'uploader removed';
  }

  /// Retracts [version] of [name], or restores it.
  Future<String> setRetracted(
    shelf.Request req,
    Principal principal,
    String name,
    String version, {
    required bool retracted,
  }) async {
    final package = await _packageForChange(name, principal);
    final target =
        package.versions.firstWhereOrNull((item) => item.version == version);
    if (target == null) {
      throw const ModerationException(HttpStatus.notFound, 'version not found');
    }

    final now = DateTime.now();
    if (retracted &&
        !principal.isAdmin &&
        app.publishPolicy.retractionWindowClosed(target.createdAt, now)) {
      throw ModerationException(
          HttpStatus.forbidden,
          'publish.retractionWindow: $name@$version can no longer be '
          'retracted. Only an administrator can retract it now.');
    }

    final changed = await app.metaStore.setVersionRetracted(name, version,
        retracted: retracted,
        retractedAt: retracted ? now : null,
        retractedBy: retracted ? principal.email : null);
    if (changed) {
      await app.audit(
        req,
        principal,
        retracted ? 'version.retracted' : 'version.unretracted',
        package: name,
        version: version,
      );
      await app.notify(
          principal, retracted ? 'version.retracted' : 'version.unretracted',
          package: name, version: version);
    }
    return retracted ? 'version retracted' : 'version restored';
  }

  /// Marks [name] as discontinued, optionally [replacedBy] another package,
  /// or as continued.
  Future<String> setDiscontinued(
    shelf.Request req,
    Principal principal,
    String name, {
    required bool discontinued,
    Object? replacedBy,
  }) async {
    if (replacedBy != null) {
      if (replacedBy is! String || !isValidPackageName(replacedBy)) {
        throw const ModerationException.invalid(
            'replacedBy must be a valid package name');
      }
      if (replacedBy == name) {
        throw const ModerationException.invalid(
            'a package cannot replace itself');
      }
      if (!discontinued) {
        throw const ModerationException.invalid(
            'replacedBy needs isDiscontinued to be true');
      }
    }

    final package = await _packageForChange(name, principal);
    final wasDiscontinued = package.isDiscontinued;
    await app.metaStore.setDiscontinued(
      name,
      discontinued: discontinued,
      replacedBy: replacedBy as String?,
      discontinuedAt: discontinued
          ? (wasDiscontinued ? package.discontinuedAt : null) ?? DateTime.now()
          : null,
    );
    await app.audit(
      req,
      principal,
      discontinued ? 'package.discontinued' : 'package.continued',
      package: name,
      details: {if (replacedBy != null) 'replacedBy': replacedBy},
    );
    if (discontinued != wasDiscontinued || replacedBy != package.replacedBy) {
      await app.notify(principal,
          discontinued ? 'package.discontinued' : 'package.continued',
          package: name,
          data: {if (replacedBy != null) 'replacedBy': replacedBy});
    }
    return discontinued ? 'package discontinued' : 'package continued';
  }

  /// Refuses everyone but an administrator who may publish.
  static void _requireAdmin(Principal principal) {
    if (!principal.isAdmin || !principal.canPublish) {
      throw const ModerationException(
          HttpStatus.forbidden, 'administrator role required');
    }
  }

  /// The package [name] as published here, refusing one that is proxied.
  Future<UnpubPackage> _localPackage(String name) async {
    final package = await app.metaStore.queryPackage(name);
    if (package == null) {
      throw ModerationException(
          HttpStatus.notFound, 'there is no package $name on this server');
    }
    if (package.private == false) {
      throw ModerationException(HttpStatus.conflict,
          '$name is mirrored from the upstream and cannot be changed here');
    }
    return package;
  }

  static ModerationException _publishInProgress(String name, String version) =>
      ModerationException(HttpStatus.conflict,
          '$name $version is being published right now, try again');

  /// Deletes [version] of [name], with its download counts and its archive.
  ///
  /// Only an administrator may. The last version cannot go: deleting the
  /// package does that. The version is reserved as a publish reserves it, so
  /// that neither can run while the other does.
  Future<String> deleteVersion(shelf.Request req, Principal principal,
      String name, String version) async {
    _requireAdmin(principal);
    var package = await _localPackage(name);
    _deletableVersion(package, version);

    final claim = await app.metaStore.reserveUpload(name, version);
    if (claim == null) throw _publishInProgress(name, version);
    final UnpubVersion target;
    final cleanupErrors = <String>[];
    final bool archiveDeleted;
    try {
      // A publish may have replaced the version before the reservation.
      package = await _localPackage(name);
      target = _deletableVersion(package, version);
      if (!await app.metaStore.removeVersion(name, version)) {
        throw _lastVersion(name, version);
      }
      // The version is gone: from here on nothing fails the deletion.
      await _cleanUp(
          cleanupErrors,
          'download counts',
          {'name': name, 'version': version},
          () => app.metaStore.removeVersionData(name, version));
      archiveDeleted = await _deleteArchive(name, target, cleanupErrors);
    } finally {
      await _release(name, version, claim);
    }
    await app.audit(req, principal, 'version.deleted',
        package: name,
        version: version,
        details: {
          if (target.sha256 != null) 'sha256': target.sha256,
          'archiveDeleted': archiveDeleted,
          if (cleanupErrors.isNotEmpty)
            'cleanupError': cleanupErrors.join('; '),
        });
    await app.notify(principal, 'version.deleted',
        package: name,
        version: version,
        data: {if (target.sha256 != null) 'sha256': target.sha256});
    return 'version deleted';
  }

  /// A reservation that cannot be given up expires by itself.
  Future<void> _release(String name, String version, String claim) async {
    try {
      await app.metaStore.releaseUpload(name, version, claim);
    } catch (error, stackTrace) {
      _log.warning(
          LogEvent('failed to release an upload reservation',
              {'name': name, 'version': version}),
          error,
          stackTrace);
    }
  }

  static ModerationException _lastVersion(String name, String version) =>
      ModerationException(
          HttpStatus.conflict,
          '$version is the only version of $name. Delete the package instead '
          'with DELETE /api/packages/$name.');

  UnpubVersion _deletableVersion(UnpubPackage package, String version) {
    final target =
        package.versions.firstWhereOrNull((item) => item.version == version);
    if (target == null) {
      throw ModerationException(
          HttpStatus.notFound, '${package.name} has no version $version');
    }
    if (package.versions.length == 1) {
      throw _lastVersion(package.name, version);
    }
    return target;
  }

  /// Deletes the package [name] with every version, archive and download
  /// count. Only an administrator may.
  ///
  /// Every version is reserved as publishing reserves it, and the document is
  /// deleted only if it still has exactly the reserved versions, so a version
  /// published meanwhile is either deleted with the rest or makes this start
  /// over. A publish that begins after the document is gone creates a new
  /// package of that name, as it would after the deletion.
  Future<String> deletePackage(
      shelf.Request req, Principal principal, String name) async {
    _requireAdmin(principal);
    for (var attempt = 0; attempt < _deleteAttempts; attempt++) {
      final package = await _localPackage(name);
      final claims = <String, String>{};
      try {
        for (final item in package.versions) {
          final claim = await app.metaStore.reserveUpload(name, item.version);
          if (claim == null) throw _publishInProgress(name, item.version);
          claims[item.version] = claim;
        }
        // Read again under the reservations, which a replacement needs too.
        final current = await _localPackage(name);
        final versions = {for (final item in current.versions) item.version};
        if (!versions.every(claims.containsKey)) continue;
        if (!await app.metaStore.deletePackage(name, versions)) continue;
        // The package is gone: from here on nothing fails the deletion.
        final cleanupErrors = <String>[];
        await _cleanUp(cleanupErrors, 'download counts and reservations',
            {'name': name}, () => app.metaStore.removePackageData(name));
        var archivesDeleted = 0;
        for (final item in current.versions) {
          if (await _deleteArchive(name, item, cleanupErrors)) {
            archivesDeleted++;
          }
        }
        await app
            .audit(req, principal, 'package.deleted', package: name, details: {
          'versions': [for (final item in current.versions) item.version],
          'uploaders': current.uploaders ?? const <String>[],
          'archivesDeleted': archivesDeleted,
          if (cleanupErrors.isNotEmpty)
            'cleanupError': cleanupErrors.join('; '),
        });
        await app.notify(principal, 'package.deleted', package: name, data: {
          'versions': [for (final item in current.versions) item.version],
        });
        return 'package deleted';
      } finally {
        for (final MapEntry(key: version, value: claim) in claims.entries) {
          await _release(name, version, claim);
        }
      }
    }
    throw ModerationException(
        HttpStatus.conflict,
        '$name keeps changing while it is deleted, try '
        'again');
  }

  /// Runs [step] of the cleanup after a deletion, logging a failure and
  /// adding it to [errors] instead of throwing, as the deletion has happened.
  static Future<void> _cleanUp(List<String> errors, String what,
      Map<String, Object?> context, Future<void> Function() step) async {
    try {
      await step();
    } catch (error, stackTrace) {
      errors.add('$what: $error');
      _log.warning(
          LogEvent('failed to remove the $what of a deleted package', context),
          error,
          stackTrace);
    }
  }

  /// Deletes the archive of [version], whose metadata is gone, and returns
  /// whether it did.
  ///
  /// An object named by its digest goes only under the lock of that digest,
  /// and only if nothing else names the digest any more. One that cannot be
  /// deleted now is an orphan that reclamation removes later. A failure is
  /// logged, added to [errors], and does not undo the deletion of the
  /// metadata.
  Future<bool> _deleteArchive(
      String name, UnpubVersion version, List<String> errors) async {
    final store = app.packageStore;
    var deleted = false;
    try {
      final digest = version.sha256;
      final references = app.metaStore.archiveReferences;
      if (version.archiveLayout != ArchiveLayout.legacy &&
          digest != null &&
          PackageStore.isDigest(digest) &&
          references != null) {
        final lock = await app.metaStore.objectLocks
            .lock(digest, timeout: _objectLockTimeout);
        if (lock != null) {
          try {
            if (!await references.isReferenced(digest) &&
                await lock.confirm()) {
              await store.deleteObject(name, version.version, digest);
              deleted = true;
            }
          } finally {
            await lock.release();
          }
        }
      }
      // Only this version names its file at the mutable path, and nothing
      // writes there any more.
      if (version.archiveLayout != ArchiveLayout.digest) {
        await store.deleteLegacy(name, version.version);
        deleted = true;
      }
    } catch (error, stackTrace) {
      errors.add('archive of ${version.version}: $error');
      _log.warning(
          LogEvent('failed to delete the archive of a deleted version',
              {'name': name, 'version': version.version}),
          error,
          stackTrace);
    }
    return deleted;
  }

  /// Makes [email], already normalized and valid, the only uploader of
  /// [name]. Only an administrator may. With user accounts, the email must be
  /// that of an existing user.
  Future<String> transferOwnership(
      shelf.Request req, Principal principal, String name, String email) async {
    _requireAdmin(principal);
    final package = await _localPackage(name);
    final accounts = app.accountApi?.accounts;
    if (accounts != null &&
        await accounts.store.findUserByEmail(normalizeEmail(email)) == null) {
      throw ModerationException(
          HttpStatus.notFound, 'there is no user with the email $email');
    }
    await app.metaStore.setUploaders(name, [email]);
    await app.audit(req, principal, 'uploader.transferred',
        package: name,
        target: email,
        details: {
          'from': package.uploaders ?? const <String>[],
          'to': email,
        });
    return 'ownership transferred';
  }
}
