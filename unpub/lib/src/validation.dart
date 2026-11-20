import 'package:pub_semver/pub_semver.dart';

/// Longest package name the registry accepts, the same limit as pub.dev.
const maxPackageNameLength = 64;

final _packageNamePattern = RegExp(r'^[a-z_][a-z0-9_]*$');

/// Whether [name] is a valid pub package name.
///
/// Names reach file paths and object keys, so anything else must be rejected
/// before it touches a store.
bool isValidPackageName(String name) =>
    name.length <= maxPackageNameLength && _packageNamePattern.hasMatch(name);

/// Whether [version] is a valid semantic version.
bool isValidPackageVersion(String version) {
  try {
    Version.parse(version);
    return true;
  } on FormatException {
    return false;
  }
}
