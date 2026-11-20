import 'package:logging/logging.dart';
import 'package:mongo_dart/mongo_dart.dart';

import '../logging.dart';

final _log = Logger('unpub.mongo');

/// The oldest MongoDB release unpub works with, as (major, minor).
///
/// The commands `mongo_dart` sends for inserts, updates and `findAndModify`
/// need the OP_MSG protocol, which arrived in 3.6.
const minimumMongoVersion = (3, 6);

/// The connected server is older than [minimumMongoVersion].
class UnsupportedMongoVersionException implements Exception {
  final String found;
  final (int, int) minimum;

  const UnsupportedMongoVersionException(this.found, this.minimum);

  @override
  String toString() => 'MongoDB $found is not supported. Unpub needs MongoDB '
      '${minimum.$1}.${minimum.$2} or later, so upgrade the server.';
}

/// Logs the version of the connected server and refuses one that is too old,
/// before a command fails later with an error that does not explain why.
///
/// [minimum] is for tests.
Future<void> checkMongoVersion(
  Db db, {
  (int, int) minimum = minimumMongoVersion,
}) async {
  // buildInfo itself needs a release that understands OP_MSG.
  if (!db.masterConnection.serverCapabilities.supportsOpMsg) {
    throw UnsupportedMongoVersionException('older than 3.6', minimum);
  }
  final reply = await db.runCommand({'buildInfo': 1});
  final version = reply['version'];
  if (version is! String) {
    _log.warning('cannot read the MongoDB version: ${reply['errmsg']}');
    return;
  }
  _log.info(LogEvent('connected to MongoDB', {'version': version}));

  final parts = RegExp(r'^(\d+)\.(\d+)').firstMatch(version);
  if (parts == null) return;
  final major = int.parse(parts[1]!);
  final minor = int.parse(parts[2]!);
  if (major < minimum.$1 || (major == minimum.$1 && minor < minimum.$2)) {
    throw UnsupportedMongoVersionException(version, minimum);
  }
}
