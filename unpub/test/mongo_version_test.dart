import 'package:mongo_dart/mongo_dart.dart';
import 'package:test/test.dart';
import 'package:unpub/unpub.dart';

import 'utils.dart';

void main() {
  late Db db;

  setUpAll(() async {
    db = Db(testMongoUri);
    await db.open();
  });

  tearDownAll(() => db.close());

  test('a supported server passes', () async {
    await checkMongoVersion(db);
  });

  test('a server below the minimum is refused with a clear message', () async {
    final buildInfo = await db.runCommand({'buildInfo': 1});
    await expectLater(
      checkMongoVersion(db, minimum: (99, 0)),
      throwsA(isA<UnsupportedMongoVersionException>().having(
        (error) => error.toString(),
        'message',
        allOf(
          contains('MongoDB ${buildInfo['version']} is not supported'),
          contains('99.0 or later'),
        ),
      )),
    );
  });
}
