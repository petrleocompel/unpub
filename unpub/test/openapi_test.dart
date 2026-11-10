import 'dart:io';

import 'package:test/test.dart';
import 'package:unpub/src/routes/openapi_document.dart';
import 'package:unpub/unpub.dart';
import 'package:yaml/yaml.dart';

import '../tool/embed_openapi.dart' as embed;
import 'harness.dart';

const _methods = {'get', 'post', 'put', 'patch', 'delete'};

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

    test('the management routes of the client are documented', () {
      for (final route in [
        'POST /api/packages/<name>/versions/<version>/retract',
        'POST /api/packages/<name>/versions/<version>/unretract',
        'PUT /api/packages/<name>/discontinue',
        'POST /api/packages/<name>/uploaders',
        'DELETE /api/packages/<name>/uploaders/<email>',
        'PUT /api/packages/<name>/owner',
        'DELETE /api/packages/<name>/versions/<version>',
        'DELETE /api/packages/<name>',
      ]) {
        expect(documented, contains(route));
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
