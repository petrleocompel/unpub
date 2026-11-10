import '../utils.dart';

/// What the pages show from a pubspec, read defensively because stored
/// pubspecs come from uploads.
class PubspecInfo {
  final Map<String, dynamic> pubspec;

  const PubspecInfo(this.pubspec);

  String get description => _string(pubspec['description']) ?? '';

  bool get isFlutter => isFlutterPubspec(pubspec);

  Map<String, dynamic> get _environment =>
      _map(pubspec['environment']) ?? const {};

  /// `environment.sdk`, the Dart SDK constraint.
  String? get sdkConstraint => _string(_environment['sdk']);

  /// `environment.flutter`, the Flutter SDK constraint.
  String? get flutterConstraint => _string(_environment['flutter']);

  /// The platforms from `platforms:`, or from `flutter.plugin.platforms` for a
  /// plugin, in the order given.
  List<String> get platforms {
    final declared = _map(pubspec['platforms']);
    if (declared != null) return declared.keys.toList();
    final flutter = _map(pubspec['flutter']);
    final plugin = _map(flutter?['plugin']);
    final pluginPlatforms = _map(plugin?['platforms']);
    if (pluginPlatforms != null) return pluginPlatforms.keys.toList();
    return const [];
  }

  /// `dependencies`, each with whether it is a hosted package that could be
  /// linked to.
  List<Dependency> get dependencies => _dependencies('dependencies');

  List<Dependency> get devDependencies => _dependencies('dev_dependencies');

  List<Dependency> _dependencies(String key) {
    final map = _map(pubspec[key]);
    if (map == null) return const [];
    return [
      for (final MapEntry(:key, :value) in map.entries)
        Dependency(key, _isHosted(value), _constraint(value)),
    ];
  }

  static bool _isHosted(Object? value) {
    if (value == null || value is String) return true;
    if (value is Map) {
      return !value.containsKey('sdk') &&
          !value.containsKey('path') &&
          !value.containsKey('git');
    }
    return false;
  }

  static String? _constraint(Object? value) {
    if (value is String) return value;
    if (value is Map) return _string(value['version']);
    return null;
  }

  /// The http or https URLs of the project, labelled.
  List<(String, Uri)> get links => [
        for (final (key, label) in const [
          ('homepage', 'Homepage'),
          ('repository', 'Repository'),
          ('issue_tracker', 'Issue tracker'),
          ('documentation', 'Documentation'),
        ])
          if (_httpUrl(pubspec[key]) case final url?) (label, url),
      ];

  static Uri? _httpUrl(Object? value) {
    final text = _string(value);
    if (text == null) return null;
    final uri = Uri.tryParse(text.trim());
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return null;
    }
    return uri.host.isEmpty ? null : uri;
  }

  static String? _string(Object? value) =>
      value is String ? value : (value is num ? '$value' : null);

  static Map<String, dynamic>? _map(Object? value) =>
      value is Map ? value.cast<String, dynamic>() : null;
}

class Dependency {
  final String name;

  /// Whether the dependency comes from a package repository, rather than the
  /// SDK, a path or git.
  final bool hosted;
  final String? constraint;

  const Dependency(this.name, this.hosted, this.constraint);
}
