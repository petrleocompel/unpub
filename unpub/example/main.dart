import 'package:logging/logging.dart';
import 'package:mongo_dart/mongo_dart.dart';
import 'package:unpub/unpub.dart' as unpub;

final _log = Logger('example');

Future<void> main(List<String> args) async {
  unpub.setupLogging(level: Level.INFO, format: unpub.LogFormat.text);

  final db = Db('mongodb://localhost:27017/dart_pub');
  await db.open(); // make sure the MongoDB connection opened

  final app = unpub.App(
    metaStore: unpub.MongoStore(db),
    packageStore: unpub.FileStore('./unpub-packages'),
    authenticator: const unpub.StaticTokenAuthenticator(
      bootstrapToken: 'replace-with-a-long-random-token',
    ),
  );

  final server = await app.serve('0.0.0.0', 4000);
  _log.info('Serving at http://${server.address.host}:${server.port}');
}
