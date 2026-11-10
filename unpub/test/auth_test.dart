import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:unpub/unpub.dart';

Request request(String method, String path, {String? authorization}) => Request(
      method,
      Uri.parse('http://localhost/$path'),
      headers: {if (authorization != null) 'authorization': authorization},
    );

void main() {
  group('static token authenticator', () {
    const authenticator = StaticTokenAuthenticator(
      bootstrapToken: 'secret',
      bootstrapEmail: 'ops@example.com',
      readTokens: {'reader-token'},
    );

    test('the bootstrap token is an admin with the configured email', () async {
      var principal = await authenticator.authenticate(request(
          'GET', 'api/packages/versions/new',
          authorization: 'Bearer secret'));
      expect(principal?.email, 'ops@example.com');
      expect(principal?.role, Role.admin);
      expect(principal?.canPublish, isTrue);
    });

    test('a read token is a reader', () async {
      var principal = await authenticator.authenticate(
          request('GET', 'x', authorization: 'Bearer reader-token'));
      expect(principal?.role, Role.reader);
      expect(principal?.scopes, {Scope.read});
      expect(principal?.canPublish, isFalse);
    });

    test('the scheme is case insensitive', () async {
      expect(
          await authenticator.authenticate(
              request('GET', 'x', authorization: 'bearer secret')),
          isNotNull);
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
      test('ignores authorization header "$header"', () async {
        expect(
            await authenticator
                .authenticate(request('GET', 'x', authorization: header)),
            isNull);
      });
    }

    for (var token in [null, '']) {
      test('bootstrap token "$token" matches nothing', () async {
        expect(
            await StaticTokenAuthenticator(bootstrapToken: token).authenticate(
                request('GET', 'x', authorization: 'Bearer anything')),
            isNull);
      });
    }
  });

  group('read gate', () {
    Principal? seen;
    final handler = const Pipeline()
        .addMiddleware(authMiddleware(
      const StaticTokenAuthenticator(
          bootstrapToken: 'write-token', readTokens: {'read-token'}),
      readAccess: ReadAccess.authenticated,
    ))
        .addHandler((request) {
      seen = principalOf(request);
      return Response.ok('inner');
    });

    setUp(() => seen = null);

    const readRoutes = [
      ['GET', ''],
      ['GET', 'packages'],
      ['GET', 'api/packages/foo'],
      ['GET', 'packages/foo/versions/1.0.0.tar.gz'],
      ['GET', 'webapi/packages'],
      ['HEAD', 'webapi/packages'],
      ['GET', 'badge/v/foo'],
      ['GET', 'healthzx'],
      ['GET', 'healthz/x'],
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
          expect(seen, isNotNull);
        });
      }
    }

    for (var path in [
      'healthz',
      'readyz',
      'healthz/',
      'readyz/',
      'healthz//',
    ]) {
      test('$path stays open', () async {
        expect((await handler(request('GET', path))).statusCode, HttpStatus.ok);
      });
    }

    test('the login endpoint stays open', () async {
      expect((await handler(request('POST', 'webapi/login'))).statusCode,
          HttpStatus.ok);
    });

    test('other account routes are not open', () async {
      expect((await handler(request('POST', 'webapi/logout'))).statusCode,
          HttpStatus.unauthorized);
      expect((await handler(request('GET', 'webapi/me'))).statusCode,
          HttpStatus.unauthorized);
    });

    for (var route in const [
      ['GET', 'api/packages/versions/new'],
      ['POST', 'api/packages/versions/newUpload'],
      ['POST', 'api/packages/foo/uploaders'],
    ]) {
      test('a read token cannot ${route[0]} ${route[1]}', () async {
        var response = await handler(
            request(route[0], route[1], authorization: 'Bearer read-token'));
        expect(response.statusCode, HttpStatus.forbidden);
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
        .addMiddleware(authMiddleware(
            const StaticTokenAuthenticator(bootstrapToken: 'secret')))
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

      test('${route[0]} ${route[1]} tolerates a wrong token', () async {
        var response = await handler(
            request(route[0], route[1], authorization: 'Bearer stale'));
        expect(response.statusCode, HttpStatus.ok);
        expect(seen, isNull);
      });
    }

    test('failures carry a challenge the pub client can print', () async {
      var response = await handler(request('GET', 'api/packages/versions/new'));
      expect(response.headers['www-authenticate'],
          allOf(startsWith('Bearer realm="pub"'), contains('message="')));
      var error = json.decode(await response.readAsString())['error'];
      expect(error['code'], 'unauthorized');
      expect(error['message'], contains('Bearer'));
    });
  });

  group('write gate for sessions and demoted tokens', () {
    final session = Session(
      id: 'id',
      userId: 'user',
      createdAt: DateTime(2026),
      expiresAt: DateTime(2027),
      csrfToken: 'csrf',
    );

    Principal? seen;
    Handler gate(Principal principal) => const Pipeline()
            .addMiddleware(authMiddleware(_FixedAuthenticator(principal)))
            .addHandler((request) {
          seen = principalOf(request);
          return Response.ok('inner');
        });

    Future<Response> write(Principal principal, String method, String path,
            {bool csrf = true}) async =>
        gate(principal)(Request(
          method,
          Uri.parse('http://localhost/$path'),
          headers: {if (csrf) 'x-csrf-token': 'csrf'},
        ));

    // With every scope, so only the role can be what refuses it.
    final readerSession = Principal('r@b.c',
        role: Role.reader,
        credentialKind: CredentialKind.session,
        session: session);

    setUp(() => seen = null);

    for (var route in const [
      ['POST', 'api/packages/versions/newUpload'],
      ['POST', 'api/packages/foo/uploaders'],
      ['DELETE', 'api/packages/foo/uploaders/a%40b.c'],
      ['PUT', 'some/future/route'],
    ]) {
      test('a reader session cannot ${route[0]} ${route[1]}', () async {
        var response = await write(readerSession, route[0], route[1]);
        expect(response.statusCode, HttpStatus.forbidden);
        expect(seen, isNull);
      });
    }

    test('a reader session cannot reach the read-only publish steps', () async {
      var response =
          await write(readerSession, 'GET', 'api/packages/versions/new');
      expect(response.statusCode, HttpStatus.forbidden);
      expect(seen, isNull);
    });

    for (var route in const [
      ['POST', 'webapi/logout'],
      ['POST', 'webapi/me/password'],
      ['POST', 'webapi/tokens'],
      ['DELETE', 'webapi/tokens/abc'],
    ]) {
      test('a reader session can ${route[0]} ${route[1]}', () async {
        var response = await write(readerSession, route[0], route[1]);
        expect(response.statusCode, HttpStatus.ok);
        expect(seen, isNotNull);
      });

      test('${route[0]} ${route[1]} still needs the CSRF token', () async {
        var response =
            await write(readerSession, route[0], route[1], csrf: false);
        expect(response.statusCode, HttpStatus.forbidden);
        expect(seen, isNull);
      });

      test('a read-only token cannot ${route[0]} ${route[1]}', () async {
        var response = await write(
            const Principal('r@b.c', role: Role.reader, scopes: {Scope.read}),
            route[0],
            route[1]);
        expect(response.statusCode, HttpStatus.forbidden);
        expect(seen, isNull);
      });
    }

    test('a token that outlived its publishing role cannot write', () async {
      var response = await write(
          const Principal('r@b.c', role: Role.reader, scopes: {Scope.publish}),
          'POST',
          'api/packages/foo/uploaders');
      expect(response.statusCode, HttpStatus.forbidden);
      expect(seen, isNull);
    });
  });

  group('email handling', () {
    test('normalizes case and whitespace', () {
      expect(normalizeEmail('  Foo@Example.COM '), 'foo@example.com');
    });

    for (var email in ['a@b', 'admin@localhost', 'first.last+tag@ex.co']) {
      test('accepts $email', () => expect(isValidEmail(email), isTrue));
    }

    for (var email in ['', 'no-at', '@b', 'a@', 'a@b@c', 'a b@c']) {
      test('rejects "$email"', () => expect(isValidEmail(email), isFalse));
    }

    test('matches uploaders ignoring case', () {
      expect(
          findEmail(['Foo@Example.com'], 'foo@example.com'), 'Foo@Example.com');
      expect(findEmail(null, 'foo@example.com'), isNull);
    });
  });

  test('parses token lifetimes', () {
    expect(parseDuration('90s'), const Duration(seconds: 90));
    expect(parseDuration('12h'), const Duration(hours: 12));
    expect(parseDuration('30d'), const Duration(days: 30));
    expect(parseDuration('2w'), const Duration(days: 14));
    for (var text in ['', '30', 'd', '0d', '-1d', '1y']) {
      expect(parseDuration(text), isNull, reason: text);
    }
  });

  group('password hasher', () {
    const light = PasswordHasher(memoryKiB: 32, iterations: 1);

    test('matches the reference Argon2id vector', () async {
      // From the test suite of the reference implementation.
      expect(
          await const PasswordHasher().verify(
              'password',
              r'$argon2id$v=19$m=65536,t=2,p=1$c29tZXNhbHQ$'
                  'CTFhFdXPJO1aFaMaO6Mm5c8y7cJHAph8ArZWb2GRPPc'),
          isTrue);
    });

    test('produces a self-describing hash that verifies', () async {
      var encoded = await light.hash('correct horse');
      expect(encoded, startsWith(r'$argon2id$v=19$m=32,t=1,p=1$'));
      expect(await light.verify('correct horse', encoded), isTrue);
      expect(await light.verify('wrong horse', encoded), isFalse);
    });

    test('uses a fresh salt', () async {
      expect(await light.hash('same'), isNot(await light.hash('same')));
    });

    test('verifies with the parameters stored in the hash', () async {
      var encoded =
          await const PasswordHasher(memoryKiB: 64, iterations: 2).hash('pw');
      expect(await light.verify('pw', encoded), isTrue);
    });

    for (var encoded in [
      '',
      'not a hash',
      r'$2b$10$abcdefghijklmnopqrstuv',
      r'$argon2id$v=19$m=999999999,t=2,p=1$c29tZXNhbHQ$AAAA',
      r'$argon2id$v=19$m=32,t=0,p=1$c29tZXNhbHQ$AAAA',
      r'$argon2id$v=19$m=32,t=1,p=1$c29tZXNhbHQ$',
    ]) {
      test('never matches the hash "$encoded"', () async {
        expect(await light.verify('password', encoded), isFalse);
      });
    }
  });

  group('login rate limiter', () {
    late DateTime now;
    late LoginRateLimiter limiter;

    setUp(() {
      now = DateTime(2026);
      limiter = LoginRateLimiter(
          maxFailures: 3,
          window: const Duration(minutes: 15),
          clock: () => now);
    });

    void fail(String address, String email) =>
        expect(limiter.acquire(address, email), isNull);

    test('blocks an email after the limit, from any address', () {
      for (var i = 0; i < 3; i++) {
        fail('10.0.0.$i', 'a@b.c');
      }
      expect(limiter.acquire('10.9.9.9', 'a@b.c'), isNotNull);
      expect(limiter.acquire('10.9.9.9', 'other@b.c'), isNull);
    });

    test('blocks an address after the limit, for any email', () {
      for (var i = 0; i < 3; i++) {
        fail('10.0.0.1', 'user$i@b.c');
      }
      expect(limiter.acquire('10.0.0.1', 'new@b.c'), isNotNull);
    });

    test('recovers after the window', () {
      for (var i = 0; i < 3; i++) {
        fail('10.0.0.1', 'a@b.c');
      }
      var wait = limiter.acquire('10.0.0.1', 'a@b.c')!;
      expect(wait, const Duration(minutes: 15));
      now = now.add(const Duration(minutes: 15));
      expect(limiter.acquire('10.0.0.1', 'a@b.c'), isNull);
    });

    test('success clears the email', () {
      fail('10.0.0.1', 'a@b.c');
      fail('10.0.0.2', 'a@b.c');
      limiter.succeeded('10.0.0.2', 'a@b.c');
      fail('10.0.0.3', 'a@b.c');
      fail('10.0.0.4', 'a@b.c');
      fail('10.0.0.5', 'a@b.c');
    });

    test('success keeps the failures of the address', () {
      fail('10.0.0.1', 'victim@b.c');
      fail('10.0.0.1', 'victim@b.c');
      fail('10.0.0.1', 'mine@b.c');
      limiter.succeeded('10.0.0.1', 'mine@b.c');
      // Only the successful attempt itself is taken back.
      fail('10.0.0.1', 'other@b.c');
      expect(limiter.acquire('10.0.0.1', 'another@b.c'), isNotNull);
    });

    group('at capacity', () {
      const window = Duration(minutes: 15);
      const refused = Duration(minutes: 1);

      LoginRateLimiter limited(int maxFailures, int maxKeys) =>
          LoginRateLimiter(
              maxFailures: maxFailures,
              maxKeys: maxKeys,
              window: window,
              clock: () => now);

      void flood(LoginRateLimiter limiter, int requests) {
        for (var i = 0; i < requests; i++) {
          limiter.acquire('flood-$i', 'flood-$i@b.c');
        }
      }

      test('a flood past capacity does not unlock an email', () {
        final limiter = limited(3, 100);
        for (var i = 0; i < 3; i++) {
          limiter.acquire('10.0.0.$i', 'victim@b.c');
        }
        flood(limiter, 1000);
        expect(limiter.acquire('10.9.9.9', 'victim@b.c'), window);
      });

      test('a flood past capacity does not unlock an address', () {
        final limiter = limited(3, 100);
        for (var i = 0; i < 3; i++) {
          limiter.acquire('10.0.0.1', 'user$i@b.c');
        }
        flood(limiter, 1000);
        expect(limiter.acquire('10.0.0.1', 'new@b.c'), window);
      });

      test('a key near the limit is kept and a low one is forgotten', () {
        final limiter = limited(4, 100);
        for (var i = 0; i < 2; i++) {
          limiter.acquire('near-$i', 'near@b.c');
        }
        limiter.acquire('low', 'low@b.c');
        flood(limiter, 1000);

        // Two more reach the limit only if the first two are remembered.
        limiter.acquire('other-1', 'near@b.c');
        limiter.acquire('other-2', 'near@b.c');
        expect(limiter.acquire('other-3', 'near@b.c'), isNotNull);

        for (var i = 0; i < 3; i++) {
          limiter.acquire('other-low-$i', 'low@b.c');
        }
        expect(limiter.acquire('other-low-3', 'low@b.c'), isNull);
      });

      test('forgets flood keys before keys with more attempts', () {
        final limiter = limited(10, 100);
        for (var i = 0; i < 4; i++) {
          limiter.acquire('near-$i', 'partly@b.c');
        }
        flood(limiter, 1000);
        for (var i = 0; i < 6; i++) {
          expect(limiter.acquire('other-$i', 'partly@b.c'), isNull);
        }
        expect(limiter.acquire('other-6', 'partly@b.c'), isNotNull);
      });

      test('expired keys make room', () {
        final limiter = limited(1, 4);
        limiter.acquire('a', 'a@b.c');
        limiter.acquire('b', 'b@b.c');
        now = now.add(window);
        expect(limiter.acquire('c', 'c@b.c'), isNull);
      });

      group('with nothing to forget', () {
        late List<LogRecord> warnings;

        setUp(() {
          warnings = [];
          final subscription = Logger.root.onRecord
              .where((record) => record.level == Level.WARNING)
              .listen(warnings.add);
          addTearDown(subscription.cancel);
        });

        test('refuses new keys and recovers after the window', () {
          final limiter = limited(1, 4);
          expect(limiter.acquire('a', 'a@b.c'), isNull);
          expect(limiter.acquire('b', 'b@b.c'), isNull);

          expect(limiter.acquire('c', 'c@b.c'), refused);
          expect(limiter.acquire('c', 'c@b.c'), refused);

          now = now.add(window);
          expect(limiter.acquire('c', 'c@b.c'), isNull);
        });

        test('refuses a known email from a new address', () {
          final limiter = limited(2, 2);
          expect(limiter.acquire('a', 'a@b.c'), isNull);
          expect(limiter.acquire('new', 'a@b.c'), refused);
        });

        test('still serves keys it already tracks', () {
          final limiter = limited(2, 2);
          expect(limiter.acquire('a', 'a@b.c'), isNull);
          expect(limiter.acquire('a', 'a@b.c'), isNull);
          expect(limiter.acquire('a', 'a@b.c'), window);
        });

        test('warns once a minute', () async {
          final limiter = limited(1, 2);
          limiter.acquire('a', 'a@b.c');

          for (var i = 0; i < 5; i++) {
            limiter.acquire('new-$i', 'new-$i@b.c');
          }
          await pumpEventQueue();
          expect(warnings, hasLength(1));

          now = now.add(const Duration(seconds: 59));
          limiter.acquire('later', 'later@b.c');
          await pumpEventQueue();
          expect(warnings, hasLength(1));

          now = now.add(const Duration(seconds: 1));
          limiter.acquire('later', 'later@b.c');
          await pumpEventQueue();
          expect(warnings, hasLength(2));
        });
      });
    });
  });
}

class _FixedAuthenticator implements Authenticator {
  final Principal principal;

  const _FixedAuthenticator(this.principal);

  @override
  Future<Principal?> authenticate(Request request) async => principal;
}
