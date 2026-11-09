import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:test/test.dart';
import 'package:unpub/unpub.dart';

void main() {
  final logger = Logger('unpub.test');

  tearDown(() => Logger.root.clearListeners());

  Future<List<String>> capture(LogFormat format, void Function() emit,
      {Level level = Level.INFO}) async {
    var lines = <String>[];
    setupLogging(level: level, format: format, sink: lines.add);
    emit();
    await Future<void>.delayed(Duration.zero);
    return lines;
  }

  test('text format appends fields', () async {
    var lines = await capture(LogFormat.text,
        () => logger.info(const LogEvent('request', {'status': 200})));
    expect(lines.single, endsWith('INFO unpub.test request status=200'));
  });

  test('text format includes the error', () async {
    var lines =
        await capture(LogFormat.text, () => logger.severe('failed', 'boom'));
    expect(lines.single, contains('failed error="boom"'));
  });

  test('json format emits one object with top-level fields', () async {
    var lines = await capture(LogFormat.json,
        () => logger.info(const LogEvent('request', {'status': 200})));
    var data = json.decode(lines.single) as Map<String, dynamic>;
    expect(data['level'], 'INFO');
    expect(data['logger'], 'unpub.test');
    expect(data['message'], 'request');
    expect(data['status'], 200);
    expect(DateTime.parse(data['time'] as String).isUtc, isTrue);
  });

  test('json format includes error and stack trace', () async {
    var lines = await capture(LogFormat.json,
        () => logger.severe('failed', 'boom', StackTrace.current));
    var data = json.decode(lines.single) as Map<String, dynamic>;
    expect(data['error'], 'boom');
    expect(data['stackTrace'], isNotEmpty);
  });

  test('json format keeps unencodable fields as strings', () async {
    var lines = await capture(LogFormat.json,
        () => logger.info(LogEvent('x', {'value': Uri.parse('http://a/')})));
    expect(json.decode(lines.single)['value'], 'http://a/');
  });

  test('fields cannot overwrite the envelope', () async {
    var lines = await capture(LogFormat.json,
        () => logger.info(const LogEvent('real', {'message': 'fake'})));
    expect(json.decode(lines.single)['message'], 'real');
  });

  test('records below the level are dropped', () async {
    var lines = await capture(LogFormat.text, () => logger.fine('hidden'));
    expect(lines, isEmpty);
  });
}
