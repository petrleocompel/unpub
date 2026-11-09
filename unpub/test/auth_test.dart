import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:unpub/unpub.dart';

Request request(String method, String path, {String? authorization}) => Request(
      method,
      Uri.parse('http://localhost/$path'),
      headers: {if (authorization != null) 'authorization': authorization},
    );

void main() {
  group('bootstrap token authenticator', () {
    const authenticator =
        BootstrapTokenAuthenticator(token: 'secret', email: 'ops@example.com');

    test('accepts the token and returns the configured email', () async {
      var principal = await authenticator.authenticate(request(
          'GET', 'api/packages/versions/new',
          authorization: 'Bearer secret'));
      expect(principal.email, 'ops@example.com');
    });

    test('the scheme is case insensitive', () async {
      await authenticator
          .authenticate(request('GET', 'x', authorization: 'bearer secret'));
    });

    for (var header in <String?>[
      null,
      'Bearer',
      'Bearer wrong',
      'Basic secret',
      'Bearer secret extra',
      // Used to pass when tokens were compared with endsWith.
      'Bearer xsecret',
    ]) {
      test('rejects authorization header "$header"', () {
        expect(
          authenticator
              .authenticate(request('GET', 'x', authorization: header)),
          throwsA(isA<AuthException>().having(
              (e) => e.statusCode, 'statusCode', HttpStatus.unauthorized)),
        );
      });
    }

    for (var token in [null, '']) {
      test('token "$token" disables publishing with a 403', () {
        expect(
          BootstrapTokenAuthenticator(token: token).authenticate(
              request('GET', 'x', authorization: 'Bearer anything')),
          throwsA(isA<AuthException>()
              .having((e) => e.statusCode, 'statusCode', HttpStatus.forbidden)
              .having((e) => e.message, 'message',
                  contains('auth.bootstrapToken'))),
        );
      });
    }
  });

  group('read gate', () {
    Principal? seen;
    final handler = const Pipeline()
        .addMiddleware(authMiddleware(
      const BootstrapTokenAuthenticator(token: 'write-token'),
      readAuthenticator:
          const ReadTokenAuthenticator({'read-token', 'write-token'}),
    ))
        .addHandler((request) {
      seen = principalOf(request);
      return Response.ok('inner');
    });

    setUp(() => seen = null);

    const readRoutes = [
      ['GET', ''],
      ['GET', 'main.dart.js'],
      ['GET', 'api/packages/foo'],
      ['GET', 'packages/foo/versions/1.0.0.tar.gz'],
      ['GET', 'webapi/packages'],
      ['HEAD', 'webapi/packages'],
      ['GET', 'badge/v/foo'],
      ['GET', 'healthz/'],
    ];

    for (var route in readRoutes) {
      test('${route[0]} /${route[1]} needs a token', () async {
        var response = await handler(request(route[0], route[1]));
        expect(response.statusCode, HttpStatus.unauthorized);
        expect(response.headers['content-type'], contains('json'));
        expect(json.decode(await response.readAsString())['error']['message'],
            contains('Bearer'));
      });

      test('${route[0]} /${route[1]} rejects a wrong token', () async {
        var response = await handler(
            request(route[0], route[1], authorization: 'Bearer wrong'));
        expect(response.statusCode, HttpStatus.unauthorized);
      });

      for (var token in ['read-token', 'write-token']) {
        test('${route[0]} /${route[1]} accepts $token', () async {
          var response = await handler(
              request(route[0], route[1], authorization: 'Bearer $token'));
          expect(response.statusCode, HttpStatus.ok);
          expect(seen, isNull);
        });
      }
    }

    for (var path in ['healthz', 'readyz']) {
      test('$path stays open', () async {
        expect((await handler(request('GET', path))).statusCode, HttpStatus.ok);
      });
    }

    for (var route in const [
      ['GET', 'api/packages/versions/new'],
      ['POST', 'api/packages/versions/newUpload'],
      ['POST', 'api/packages/foo/uploaders'],
    ]) {
      test('a read token cannot ${route[0]} ${route[1]}', () async {
        var response = await handler(
            request(route[0], route[1], authorization: 'Bearer read-token'));
        expect(response.statusCode, HttpStatus.unauthorized);
        expect(seen, isNull);
      });

      test('the bootstrap token can ${route[0]} ${route[1]}', () async {
        var response = await handler(
            request(route[0], route[1], authorization: 'Bearer write-token'));
        expect(response.statusCode, HttpStatus.ok);
        expect(seen, isNotNull);
      });
    }
  });

  group('auth middleware', () {
    Principal? seen;
    final handler = const Pipeline()
        .addMiddleware(
            authMiddleware(const BootstrapTokenAuthenticator(token: 'secret')))
        .addHandler((request) {
      seen = principalOf(request);
      return Response.ok('inner');
    });

    setUp(() => seen = null);

    const protectedRoutes = [
      ['GET', 'api/packages/versions/new'],
      ['POST', 'api/packages/versions/newUpload'],
      ['GET', 'api/packages/versions/newUploadFinish'],
      ['POST', 'api/packages/foo/uploaders'],
      ['DELETE', 'api/packages/foo/uploaders/a%40b.c'],
    ];

    for (var route in protectedRoutes) {
      test('${route[0]} ${route[1]} needs a token', () async {
        var response = await handler(request(route[0], route[1]));
        expect(response.statusCode, HttpStatus.unauthorized);
        expect(seen, isNull);
      });

      test('${route[0]} ${route[1]} passes with the token', () async {
        var response = await handler(
            request(route[0], route[1], authorization: 'Bearer secret'));
        expect(response.statusCode, HttpStatus.ok);
        expect(seen?.email, 'admin@localhost');
      });
    }

    const undeclaredWrites = [
      ['POST', 'some/future/route'],
      ['PUT', 'api/packages/foo'],
      ['PATCH', 'webapi/packages'],
      ['DELETE', 'api/packages/foo'],
      ['PROPFIND', 'api/packages/foo'],
      ['post', 'api/packages/foo'],
    ];

    for (var route in undeclaredWrites) {
      test('${route[0]} ${route[1]} is denied by default', () async {
        var response = await handler(request(route[0], route[1]));
        expect(response.statusCode, HttpStatus.unauthorized);
        expect(seen, isNull);
      });
    }

    const publicRoutes = [
      ['GET', 'api/packages/foo'],
      ['GET', 'api/packages/foo/versions/1.0.0'],
      ['GET', 'packages/foo/versions/1.0.0.tar.gz'],
      ['GET', 'webapi/packages'],
      ['GET', 'healthz'],
      ['HEAD', 'api/packages/foo'],
      ['OPTIONS', 'api/packages/versions/new'],
      ['OPTIONS', 'api/packages/foo/uploaders'],
    ];

    for (var route in publicRoutes) {
      test('${route[0]} ${route[1]} stays public', () async {
        var response = await handler(request(route[0], route[1]));
        expect(response.statusCode, HttpStatus.ok);
      });
    }

    test('failures carry a challenge the pub client can print', () async {
      var response = await handler(request('GET', 'api/packages/versions/new'));
      expect(response.headers['www-authenticate'],
          allOf(startsWith('Bearer realm="pub"'), contains('message="')));
      expect(json.decode(await response.readAsString())['error']['message'],
          contains('Bearer'));
    });
  });
}
