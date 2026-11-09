import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

/// Output format of log records.
enum LogFormat { text, json }

/// A log message with structured fields.
///
/// Pass it to any [Logger] method. The JSON format emits [fields] as top-level
/// properties and the text format appends them as `key=value` pairs.
class LogEvent {
  final String message;
  final Map<String, Object?> fields;

  const LogEvent(this.message, [this.fields = const {}]);

  @override
  String toString() {
    if (fields.isEmpty) return message;
    final pairs = fields.entries.map((e) => '${e.key}=${e.value}').join(' ');
    return '$message $pairs';
  }
}

/// Formats [record] as a single line of text.
String formatTextRecord(LogRecord record) {
  final buffer = StringBuffer()
    ..write(record.time.toUtc().toIso8601String())
    ..write(' ')
    ..write(record.level.name)
    ..write(' ')
    ..write(record.loggerName.isEmpty ? 'root' : record.loggerName)
    ..write(' ')
    ..write(record.message);
  if (record.error != null) buffer.write(' error="${record.error}"');
  if (record.stackTrace != null) buffer.write('\n${record.stackTrace}');
  return buffer.toString();
}

/// Formats [record] as a single line of JSON.
String formatJsonRecord(LogRecord record) {
  final object = record.object;
  final data = <String, Object?>{
    'time': record.time.toUtc().toIso8601String(),
    'level': record.level.name,
    'logger': record.loggerName.isEmpty ? 'root' : record.loggerName,
    'message': object is LogEvent ? object.message : record.message,
  };
  if (object is LogEvent) {
    for (final entry in object.fields.entries) {
      data.putIfAbsent(entry.key, () => entry.value);
    }
  }
  if (record.error != null) data['error'] = record.error.toString();
  if (record.stackTrace != null) {
    data['stackTrace'] = record.stackTrace.toString();
  }
  return json.encode(data, toEncodable: (value) => value.toString());
}

/// Routes all log records at [level] or above to [sink] (stdout by default).
///
/// Returns the subscription so callers can stop logging.
StreamSubscription<LogRecord> setupLogging({
  required Level level,
  required LogFormat format,
  void Function(String line)? sink,
}) {
  final write = sink ?? stdout.writeln;
  final render = switch (format) {
    LogFormat.text => formatTextRecord,
    LogFormat.json => formatJsonRecord,
  };
  Logger.root.level = level;
  return Logger.root.onRecord.listen((record) => write(render(record)));
}
