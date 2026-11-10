import 'dart:io';

import 'package:collection/collection.dart' show IterableExtension;
import 'package:shelf/shelf.dart' as shelf;

import 'app.dart';
import 'auth/authenticator.dart';
import 'models.dart';
import 'routes/route_support.dart';
import 'validation.dart';

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

/// The rules for changing uploaders, retraction and the discontinued flag,
/// shared by the pub API and the admin pages. Every change is audited.
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
    await app.audit(req, principal, 'uploader.added', name, {'email': email});
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
    await app
        .audit(req, principal, 'uploader.removed', name, {'email': stored});
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
        '$name@$version',
      );
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
      name,
      {if (replacedBy != null) 'replacedBy': replacedBy},
    );
    return discontinued ? 'package discontinued' : 'package continued';
  }
}
