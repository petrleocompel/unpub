# Unpub

Unpub is a self-hosted private Dart Pub server for teams, with a simple web interface to search and view package information. It is a single binary that stores metadata in MongoDB and package archives on disk or in S3.

> **This is a modernization in progress.** Authentication is temporary: a single shared token gates publishing, and optional shared tokens gate reading, until user accounts arrive. The plan for accounts, policies, the new web UI and administration is in [docs/ROADMAP.md](docs/ROADMAP.md).

![Screenshot](assets/screenshot.png)

## Quick start with Docker

```sh
cat > .env <<EOT
UNPUB_AUTH_BOOTSTRAP_TOKEN=$(openssl rand -hex 32)
UNPUB_SERVER_PUBLIC_URL=http://localhost:4000
EOT

docker compose up -d --build
curl http://localhost:4000/readyz
```

## Publishing and consuming packages

Give the Dart client the token and set the server in the package's `pubspec.yaml`:

```sh
dart pub token add http://localhost:4000 # paste the value of UNPUB_AUTH_BOOTSTRAP_TOKEN
```

```yaml
publish_to: http://localhost:4000
```

Then run `dart pub publish`. To depend on a package:

```yaml
dependencies:
  my_package:
    hosted: http://localhost:4000
    version: ^1.0.0
```

Packages not found locally redirect to the upstream, pub.dev by default, so setting `PUB_HOSTED_URL` to this server also works for mixed dependency trees.

Reading is public by default, and only publishing and uploader management need the token. To make the registry private, set `auth.readAccess: authenticated`. Every route except `/healthz` and `/readyz` then needs a Bearer token from `auth.readTokens`, or the bootstrap token, which `dart pub get` sends once added with `dart pub token add`. The embedded web UI cannot send tokens, so it does not work in that mode until the new UI arrives.

Dart clients only send tokens over HTTPS, except to localhost, so deploy behind TLS.

## Running from source

Requires the Dart SDK and a MongoDB instance.

```sh
docker compose -f docker-compose.dev.yml up -d mongo
cd unpub
dart pub get
dart run bin/unpub.dart serve --config ../unpub.example.yaml
```

To build a standalone binary, run `dart compile exe bin/unpub.dart -o unpub`.

## Command line

| Command | Description |
| --- | --- |
| `unpub serve [--config path] [--host address] [--port number]` | Start the server. |
| `unpub version` | Print the version. |
| `unpub --help` | Print usage. |
| `unpub migrate`, `unpub admin` | Reserved for later phases. They exit with code 2. |

## Configuration

Settings are resolved in this order, with later ones winning: built-in defaults, the YAML file, environment variables, then the `--host` and `--port` flags. Startup fails with a list of every problem if the configuration is invalid.

The file is `unpub.yaml` in the working directory, or the path given with `--config`. See [unpub.example.yaml](unpub.example.yaml) for a commented example.

Any key can be set through a variable named `UNPUB_<SECTION>_<KEY>`. CamelCase keys take underscores, so `server.publicUrl` is `UNPUB_SERVER_PUBLIC_URL`.

| Key | Environment variable | Default | Description |
| --- | --- | --- | --- |
| `server.host` | `UNPUB_SERVER_HOST` | `0.0.0.0` | Listen address. |
| `server.port` | `UNPUB_SERVER_PORT` | `4000` | Listen port. |
| `server.publicUrl` | `UNPUB_SERVER_PUBLIC_URL` | derived from the request | External origin, used in archive and upload URLs. Set it behind a reverse proxy. |
| `mongo.uri` | `UNPUB_MONGO_URI` | `mongodb://localhost:27017/dart_pub` | MongoDB URI, including the database name. |
| `storage.type` | `UNPUB_STORAGE_TYPE` | `file` | `file` or `s3`. |
| `storage.file.path` | `UNPUB_STORAGE_FILE_PATH` | `unpub-packages` | Directory for archives. |
| `storage.s3.bucket` | `UNPUB_STORAGE_S3_BUCKET` | | Bucket name. Required for `s3`. |
| `storage.s3.region` | `UNPUB_STORAGE_S3_REGION` | `AWS_DEFAULT_REGION` | Region. Required for `s3`. |
| `storage.s3.endpoint` | `UNPUB_STORAGE_S3_ENDPOINT` | `AWS_S3_ENDPOINT` or `s3.amazonaws.com` | Host name of the S3 service. |
| `storage.s3.port` | `UNPUB_STORAGE_S3_PORT` | | Port of the S3 service. |
| `storage.s3.useSSL` | `UNPUB_STORAGE_S3_USE_SSL` | `true` | Use HTTPS. |
| `storage.s3.pathStyle` | `UNPUB_STORAGE_S3_PATH_STYLE` | automatic | Force path-style bucket addressing. |
| `storage.s3.accessKey` | `UNPUB_STORAGE_S3_ACCESS_KEY` | `AWS_ACCESS_KEY_ID` | Access key. |
| `storage.s3.secretKey` | `UNPUB_STORAGE_S3_SECRET_KEY` | `AWS_SECRET_ACCESS_KEY` | Secret key. |
| `storage.s3.sessionToken` | `UNPUB_STORAGE_S3_SESSION_TOKEN` | `AWS_SESSION_TOKEN` | Session token. |
| `upstream.url` | `UNPUB_UPSTREAM_URL` | `https://pub.dev` | Where unknown packages redirect. |
| `auth.bootstrapToken` | `UNPUB_AUTH_BOOTSTRAP_TOKEN` | | Bearer token for publishing and uploader management. Publishing is disabled while unset. |
| `auth.bootstrapEmail` | `UNPUB_AUTH_BOOTSTRAP_EMAIL` | `admin@localhost` | Uploader recorded for token publishes. |
| `auth.readAccess` | `UNPUB_AUTH_READ_ACCESS` | `public` | `public`, or `authenticated` to require a Bearer token on every route except `/healthz` and `/readyz`. |
| `auth.readTokens` | `UNPUB_AUTH_READ_TOKENS` | | Tokens that may read but not publish. A YAML list, or comma separated in the environment. |
| `logging.level` | `UNPUB_LOGGING_LEVEL` | `info` | `fine`, `info`, `warning`, `severe` and other `package:logging` levels, or `off`. |
| `logging.format` | `UNPUB_LOGGING_FORMAT` | `text` | `text` or `json`. |

Without `storage.s3.accessKey`, S3 credentials come from the standard AWS variables or the ECS task role.

### Upgrading from 2.x

- The `--database` and `--proxy-origin` flags and the `proxy-origin` header are replaced by `mongo.uri` and `server.publicUrl`.
- Google sign-in is gone. The environment variables map as follows:

  | 2.x | 3.x |
  | --- | --- |
  | `UPLOAD_TOKEN` | `auth.bootstrapToken` |
  | `UPLOAD_EMAIL` | `auth.bootstrapEmail` |
  | `ALLOWED_TOKENS` | `auth.readAccess: authenticated` and `auth.readTokens` |

- A registry that set `ALLOWED_TOKENS` was private. It becomes world-readable unless you set `auth.readAccess: authenticated`, which is not the default.
- The embedded web UI cannot send tokens, so it is unusable in `authenticated` mode, as it was with `ALLOWED_TOKENS`, until the new UI replaces it.
- `auth.bootstrapEmail` must match an email already present in the `uploaders` of your existing packages, because publishing to a package requires being on that list.
- Package names must now match `[a-z_][a-z0-9_]*` and be at most 64 characters long. A stored package with any other name is no longer reachable.
- MongoDB documents and the archive layout are unchanged. Archives stay in `unpub-packages` by default.

### Behind a reverse proxy

Set `server.publicUrl` to the external origin, and use HTTP/1.1 towards unpub:

```nginx
proxy_http_version 1.1;
proxy_set_header Host $host;
client_max_body_size 100m;
```

## Operations

| Endpoint | Description |
| --- | --- |
| `GET /healthz` | Returns 200 while the process is up. |
| `GET /readyz` | Checks MongoDB and storage. Returns 200, or 503 with JSON details. |

The server logs one line per request to stdout, in text or JSON. On SIGINT or SIGTERM it stops accepting connections, drains requests for up to 30 seconds and closes MongoDB. A second signal exits immediately.

The server does not reconnect after losing its MongoDB connection. `/readyz` then keeps returning 503 until the process is restarted, so restart it when that happens.

## Using unpub as a library

The `App` class can be embedded for custom stores or upload rules.

```dart
import 'package:mongo_dart/mongo_dart.dart';
import 'package:unpub/unpub.dart' as unpub;

Future<void> main() async {
  final db = Db('mongodb://localhost:27017/dart_pub');
  await db.open();

  final app = unpub.App(
    metaStore: unpub.MongoStore(db),
    packageStore: unpub.FileStore('./unpub-packages'),
    authenticator: const unpub.BootstrapTokenAuthenticator(
      token: 'a-long-random-token',
    ),
    uploadValidator: (pubspec, uploaderEmail) async {
      // Throw to reject the upload.
      final name = pubspec['name'] as String;
      if (!name.startsWith('my_company_')) {
        throw 'Package name should start with my_company_';
      }
    },
  );

  await app.serve('0.0.0.0', 4000);
}
```

`MetaStore`, `PackageStore` and `Authenticator` can each be replaced by your own implementation. `S3Store` and `FileStore` are included.

## Badges

| URL | Badge |
| --- | --- |
| `/badge/v/{package_name}` | ![badge example](https://img.shields.io/static/v1?label=unpub&message=1.0.0&color=blue) |
| `/badge/d/{package_name}` | ![badge example](https://img.shields.io/static/v1?label=downloads&message=123&color=blue) |

## Development

```sh
docker compose -f docker-compose.dev.yml up -d mongo
cd unpub
dart test
```

Set `UNPUB_TEST_MONGO_URI` to use another database. The S3 tests run when `UNPUB_TEST_S3_ENDPOINT` points to an S3 compatible service. Run `make generate` after changing routes or models. Commits follow [Conventional Commits](https://www.conventionalcommits.org).

## Credits

- [pub-dev](https://github.com/dart-lang/pub-dev): web page styles are mostly taken from https://pub.dev.
- [shields](https://shields.io): badge generation.
- [bytedance/unpub](https://github.com/bytedance/unpub): the project this is forked from.

## License

MIT
