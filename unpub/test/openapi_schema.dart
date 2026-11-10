import 'package:test/test.dart';
import 'package:unpub/src/routes/openapi_document.dart';
import 'package:yaml/yaml.dart';

final YamlMap _document = loadYaml(openApiDocument) as YamlMap;

/// The schemas of the embedded OpenAPI document.
final YamlMap _schemas = _document['components']['schemas'] as YamlMap;

/// Expects [json], the answer with [status] to [method] [path] (concrete,
/// without the query), to have the shape the document gives that answer.
void expectResponse(String method, String path, int status, Object? json) {
  final operation = _operation(method, path);
  expect(operation, isNotNull, reason: '$method $path is not documented');
  final responses = operation!['responses'] as YamlMap;
  var response = responses['$status'] ?? responses['${status ~/ 100}XX'];
  expect(response, isNotNull, reason: '$method $path: no $status documented');
  if (response case {r'$ref': final String ref}) {
    response = _document['components']['responses'][ref.split('/').last];
  }
  final schema = response['content']?['application/json']?['schema'];
  expect(schema, isNotNull, reason: '$method $path $status: no JSON schema');
  expect(_problems(json, schema, '$method $path $status'), isEmpty);
}

YamlMap? _operation(String method, String path) {
  YamlMap? best;
  var fewest = 1 << 30;
  for (final MapEntry(key: template, value: item)
      in (_document['paths'] as YamlMap).entries) {
    final pattern =
        RegExp('^${'$template'.replaceAll(RegExp(r'\{\w+\}'), '[^/]+')}\$');
    final parameters = '{'.allMatches('$template').length;
    if (pattern.hasMatch(path) && parameters < fewest) {
      final operation = (item as YamlMap)[method.toLowerCase()] as YamlMap?;
      if (operation != null) {
        best = operation;
        fewest = parameters;
      }
    }
  }
  return best;
}

/// Expects [json] to have the shape of the schema [name] of the OpenAPI
/// document: every `required` key, and the primitive `type`, `const` and
/// `enum` of every value, following `$ref`, `allOf`, `oneOf`, `items` and
/// `properties`. Formats, patterns and bounds are not checked.
void expectSchema(Object? json, String name) =>
    expect(schemaProblems(json, name), isEmpty, reason: 'does not match $name');

/// What keeps [json] from having the shape of the schema [name], see
/// [expectSchema].
List<String> schemaProblems(Object? json, String name) =>
    _problems(json, _schemas[name], name);

YamlMap _resolve(Object? schema) {
  var current = schema as YamlMap;
  for (var ref = current[r'$ref']; ref is String; ref = current[r'$ref']) {
    current = _schemas[ref.split('/').last] as YamlMap;
  }
  return current;
}

void _check(Object? value, Object? raw, String path, List<String> problems) {
  final schema = _resolve(raw);

  for (final part in schema['allOf'] as YamlList? ?? const []) {
    _check(value, part, path, problems);
  }
  if (schema['oneOf'] case final YamlList options) {
    final failures = [
      for (final option in options) _problems(value, option, path),
    ];
    if (failures.every((found) => found.isNotEmpty)) {
      problems.add('$path matches no option of oneOf: '
          '${failures.map((found) => found.join('; ')).join(' | ')}');
    }
  }

  final types = switch (schema['type']) {
    null => null,
    final String type => [type],
    final YamlList list => list.cast<String>(),
    _ => null,
  };
  if (types != null && !types.any((type) => _isType(value, type))) {
    problems.add('$path is ${value.runtimeType} `$value`, not $types');
    return;
  }
  if (schema.containsKey('const') && value != schema['const']) {
    problems.add('$path is `$value`, not `${schema['const']}`');
  }
  if (schema['enum'] case final YamlList values when value != null) {
    if (!values.contains(value)) problems.add('$path `$value` not in $values');
  }

  if (value is Map) {
    for (final key in schema['required'] as YamlList? ?? const []) {
      if (!value.containsKey(key)) problems.add('$path lacks `$key`');
    }
    final properties = schema['properties'] as YamlMap? ?? YamlMap();
    for (final MapEntry(:key, value: property) in properties.entries) {
      if (value.containsKey(key)) {
        _check(value[key], property, '$path.$key', problems);
      }
    }
  } else if (value is List && schema['items'] != null) {
    for (final (index, item) in value.indexed) {
      _check(item, schema['items'], '$path[$index]', problems);
    }
  }
}

List<String> _problems(Object? value, Object? schema, String path) {
  final found = <String>[];
  _check(value, schema, path, found);
  return found;
}

bool _isType(Object? value, String type) => switch (type) {
      'null' => value == null,
      'string' => value is String,
      'integer' => value is int,
      'number' => value is num,
      'boolean' => value is bool,
      'array' => value is List,
      'object' => value is Map,
      _ => true,
    };
