import 'dart:io';

import 'package:unpub/src/cli/cli.dart';

Future<void> main(List<String> args) async {
  final code = await runCli(args);
  await Future.wait([stdout.flush(), stderr.flush()]);
  exit(code);
}
