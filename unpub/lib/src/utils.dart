import 'package:yaml/yaml.dart';

dynamic convertYaml(dynamic value) {
  if (value is YamlMap) {
    return value
        .cast<String, dynamic>()
        .map((k, v) => MapEntry(k, convertYaml(v)));
  }
  if (value is YamlList) {
    return value.map((e) => convertYaml(e)).toList();
  }
  return value;
}

Map<String, dynamic>? loadYamlAsMap(dynamic value) {
  var yamlMap = loadYaml(value) as YamlMap?;
  return convertYaml(yamlMap).cast<String, dynamic>();
}

List<String> getPackageTags(Map<String, dynamic> pubspec) {
  // TODO: web and other tags
  if (pubspec['flutter'] != null) {
    return ['flutter'];
  } else {
    return ['flutter', 'web', 'other'];
  }
}

/// Whether [pubspec] is that of a Flutter package: it has a `flutter`
/// section, an `environment.flutter` constraint or depends on `flutter`.
bool isFlutterPubspec(Map<String, dynamic> pubspec) {
  if (pubspec.containsKey('flutter')) return true;
  final environment = pubspec['environment'];
  if (environment is Map && environment.containsKey('flutter')) return true;
  final dependencies = pubspec['dependencies'];
  return dependencies is Map && dependencies.containsKey('flutter');
}
