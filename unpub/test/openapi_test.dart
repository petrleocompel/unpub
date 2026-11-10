import 'dart:io';

import 'package:test/test.dart';
import 'package:unpub/src/routes/openapi_document.dart';
import 'package:unpub/unpub.dart';
import 'package:yaml/yaml.dart';

import '../tool/embed_openapi.dart' as embed;
import 'harness.dart';

const _methods = {'get', 'post', 'put', 'patch', 'delete'};

/// The routes under `/api` that `dart pub` speaks, described by the pub
/// repository specification rather than by docs/openapi.yaml. Every other
/// `/api` route is one of the client and must be documented.
const _pubProtocolRoutes = {
  'GET /api/packages/<name>',
  'GET /api/packages/<name>/advisories',
  'GET /api/packages/<name>/versions/<version>',
  'GET /api/packages/versions/new',
  'POST /api/packages/versions/newUpload',
  'GET /api/packages/versions/newUploadFinish',
};

/// The error codes in the sources: those given to `badRequest`, the account
/// and auth exceptions and helpers, and the defaults of [errorCodeFor].
Set<String> _emittedErrorCodes() {
  final patterns = [
    RegExp(r"\bcode(?:: | = )'([a-z_]+)'"),
    RegExp(r"'code': '([a-z_]+)'"),
    RegExp(r"_error\(\s*HttpStatus\.\w+,\s*'([a-z_]+)'"),
    RegExp(r"HttpStatus\.\w+ => '([a-z_]+)'"),
    RegExp(r"status >= 500 \? '([a-z_]+)' : '([a-z_]+)'"),
  ];
  final codes = <String>{};
  for (final file in Directory('lib').listSync(recursive: true)) {
    if (file is! File || !file.path.endsWith('.dart')) continue;
    if (file.path.endsWith('openapi_document.dart')) continue;
    final source = file.readAsStringSync();
    for (final pattern in patterns) {
      for (final match in pattern.allMatches(source)) {
        for (var group = 1; group <= match.groupCount; group++) {
          codes.add(match[group]!);
        }
      }
    }
  }
  return codes;
}

/// docs/openapi.yaml against the routes the app registers.
void main() {
  final file = File(embed.source);
  final document = loadYaml(file.readAsStringSync()) as YamlMap;

  /// The documented routes, as `METHOD /path/<param>` like the router has
  /// them.
  final documented = {
    for (final MapEntry(key: path, value: item)
        in (document['paths'] as YamlMap).entries)
      for (final method in (item as YamlMap).keys)
        if (_methods.contains(method))
          '${'$method'.toUpperCase()} '
              '${'$path'.replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) => '<${m[1]}>')}',
  };

  test('the served copy is the document', () {
    expect(openApiDocument, file.readAsStringSync(),
        reason: 'run dart run tool/embed_openapi.dart');
    expect(embed.embedded(file.readAsStringSync()),
        File(embed.target).readAsStringSync(),
        reason: 'run dart run tool/embed_openapi.dart');
  });

  test('is OpenAPI 3.1 for this version', () {
    expect(document['openapi'], '3.1.0');
    expect(document['info']['version'], packageVersion);
  });

  test('every reference resolves', () {
    final components = document['components'] as YamlMap;
    final text = file.readAsStringSync();
    for (final match
        in RegExp(r"\$ref: '#/components/(\w+)/(\w+)'").allMatches(text)) {
      expect((components[match[1]] as YamlMap?)?.containsKey(match[2]), isTrue,
          reason: match[0]);
    }
    final schemes = (components['securitySchemes'] as YamlMap).keys.toSet();
    expect(schemes, containsAll(['cookieAuth', 'csrfHeader', 'bearerAuth']));
    for (final item in (document['paths'] as YamlMap).values) {
      for (final MapEntry(key: method, value: operation)
          in (item as YamlMap).entries) {
        if (!_methods.contains(method)) continue;
        expect((operation as YamlMap)['responses'], isNotEmpty);
        for (final requirement in operation['security'] ?? const []) {
          expect(schemes, containsAll((requirement as YamlMap).keys));
        }
      }
    }
  });

  group('against the router', () {
    final harness = Harness(
        builder: (h) => h.buildApp(
            webhooks: WebhookService(WebhookStore(h.db),
                config: const WebhooksConfig(), audit: h.audit)));
    harness.install();

    Set<String> registered() => {
          for (final (verb, route) in harness.app.router.routes) '$verb $route',
        };

    test('every documented route exists', () {
      final routes = registered();
      for (final route in documented) {
        expect(routes, contains(route), reason: 'documented, not registered');
      }
    });

    test('every /webapi route is documented', () {
      for (final route in registered()) {
        if (!route.split(' ').last.startsWith('/webapi/')) continue;
        expect(documented, contains(route),
            reason: 'registered, not documented');
      }
    });

    test('every /api route is documented, but the pub protocol', () {
      final api = {
        for (final route in registered())
          if (route.split(' ').last.startsWith('/api/')) route,
      };
      expect(api, containsAll(_pubProtocolRoutes),
          reason: 'an allowlisted route is no longer registered');
      final management = api.difference(_pubProtocolRoutes);
      final documentedApi = {
        for (final route in documented)
          if (route.split(' ').last.startsWith('/api/')) route,
      };
      expect(documentedApi, management,
          reason: 'registered and documented /api routes differ');
      expect(management, isNotEmpty);
    });

    test('lists every error code the server emits', () {
      final intro = document['info']['description'] as String;
      for (final code in _emittedErrorCodes()) {
        expect(intro, contains('`$code`'), reason: 'undocumented code');
      }
    });

    test('is served at /webapi/openapi.yaml, also to anonymous readers',
        () async {
      final private = harness.buildApp(readAccess: ReadAccess.authenticated);
      final reply =
          await harness.send('GET', '/webapi/openapi.yaml', using: private);
      expect(reply.status, HttpStatus.ok);
      expect(reply.headers['content-type'], startsWith('application/yaml'));
      expect(reply.body, openApiDocument);
    });
  });
}
