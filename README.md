# Unpub

Unpub is a self-hosted private Dart Pub server for teams, with a simple web interface to search and view package information. It is a single binary that stores metadata in MongoDB and package archives on disk or in S3.

> **This is a modernization in progress.** User accounts, roles, personal API tokens, publishing policies and an upstream proxy are in place. The plan for the new web UI and administration is in [docs/ROADMAP.md](docs/ROADMAP.md).

![Screenshot](assets/screenshot.png)

## Quick start with Docker

```sh
cat > .env <<EOT
UNPUB_AUTH_ADMIN_EMAIL=you@example.com
UNPUB_AUTH_ADMIN_PASSWORD=$(openssl rand -hex 16)
UNPUB_SERVER_PUBLIC_URL=http://localhost:4000
EOT

docker compose up -d --build
curl http://localhost:4000/readyz
docker compose exec unpub /app/unpub admin create-token --email you@example.com --name laptop
```

The first start creates the administrator. The last command prints an API token, once.

## Publishing and consuming packages

Give the Dart client a personal token and set the server in the package's `pubspec.yaml`:

```sh
dart pub token add http://localhost:4000 # paste the token secret
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

Packages not found locally redirect to the upstream, pub.dev by default, so setting `PUB_HOSTED_URL` to this server also works for mixed dependency trees. See [Upstream proxy](#upstream-proxy) to fetch and keep them here instead.

Reading is public by default, and only publishing and uploader management need a token. To make the registry private, set `auth.readAccess: authenticated`. Every route except `/healthz`, `/readyz` and the login endpoint then needs a token or session, which `dart pub get` provides once the token is added with `dart pub token add`. The embedded web UI cannot send tokens, so it does not work in that mode until the new UI arrives. Badges under `/badge/...` and every other anonymous GET answer 401 as well, so shields.io and similar scrapers cannot fetch them from a private registry.

Dart clients only send tokens over HTTPS, except to localhost, so deploy behind TLS.

## Authentication

### Roles

| Role | May |
| --- | --- |
| `admin` | Everything: manage users, publish to any package, manage the uploaders of any package, retract or discontinue any package. |
| `publisher` | Publish new packages, publish to packages where their email is in `uploaders`, and manage the uploaders, retraction and discontinued state of those packages. |
| `reader` | Read only, and look after their own account: log out, change their password, manage their own `read` tokens. This matters when `auth.readAccess` is `authenticated`. |

Package `uploaders` remain a list of email addresses, matched against the authenticated user ignoring case. A package without an `uploaders` list can only be changed by an administrator.

### Tokens and sessions

A request is authenticated by the first of these that matches. Anything else is anonymous.

1. `Authorization: Bearer <secret>` with a personal token that is neither revoked nor expired.
2. The `unpub_session` cookie from `POST /webapi/login`. Requests other than GET, HEAD and OPTIONS must also send its CSRF token, in the `X-CSRF-Token` header or the `csrf_token` form field.
3. The deprecated static tokens: `auth.bootstrapToken` acts as an administrator with the email `auth.bootstrapEmail`, and each entry of `auth.readTokens` acts as a reader. The server logs a warning when they are set. Move to personal tokens.

Personal tokens have the scopes `read` and `publish`. A scope narrows what the role allows and never widens it, so a `read` token cannot change anything even for an administrator. A session holds the scopes its role allows. Only the hash of a secret is stored. It is shown once, when created.

Credentials and roles can only be changed with a password login or `unpub admin`. Every kind of token, including `auth.bootstrapToken`, gets 403 with the code `session_required` when it tries to create a user, set a password or change a user. A token can still create tokens for its own user, within its own scopes and expiry, and revoke tokens of its own user.

```sh
unpub admin create-token --email you@example.com --name laptop --scopes read,publish --expires-in 90d
dart pub token add https://pub.example.com
```

### Administrators

Set `auth.admin.email` and `auth.admin.password` (or `UNPUB_AUTH_ADMIN_EMAIL` and `UNPUB_AUTH_ADMIN_PASSWORD`) to create the first administrator when the server starts with no users. Once any user exists, including the placeholders made by `unpub migrate`, these values are ignored and the server logs that. Use `unpub admin` from then on.

| Command | Description |
| --- | --- |
| `unpub admin create-user --email <address> --role <role> [--display-name <name>] [--password <secret> \| --password-stdin]` | Create a user. Without a password it is a placeholder that cannot log in. `--password` is visible in the process list. |
| `unpub admin set-password --email <address> [--password-stdin]` | Set a password, prompting on a terminal. Ends the sessions of the user. |
| `unpub admin set-role --email <address> --role <role>` | Change a role. |
| `unpub admin disable --email <address>`, `unpub admin enable --email <address>` | Disable or re-enable a user. A disabled user's tokens and sessions stop working. |
| `unpub admin list-users` | List users. |
| `unpub admin create-token --email <address> --name <label> [--scopes read,publish] [--expires-in 30d]` | Print a new token secret. Lifetimes use `s`, `m`, `h`, `d` or `w`. |

Each takes `--config <path>`. The last enabled administrator cannot be demoted or disabled. The ids of the enabled administrators are kept in one document, `enabled_admins` in the `admin_set` collection. Taking someone out of it is a single atomic update that refuses to empty it. The server and every `unpub admin` command except `list-users` rebuild this document from `users` when they start.

**Last admin protection.** The guard prevents the common mistakes, such as demoting or disabling the last administrator, or two administrators removing each other at the same moment. These answer 409 with the code `last_admin`, `admin_change_in_progress` or `conflict`; `conflict` also covers an admin set that kept changing under the retries, which simply means try again. It is a safety net against mistakes, not a security boundary. MongoDB cannot change the `users` collection and the admin set in one transaction, so every change of an existing user writes the set first and the user second, and writes the user only if its role and disabled state are still what the decision was based on. Creating a user as an administrator is the one exception: the user is inserted first, because it has no id before that, and is read again after joining the set. Under pathological concurrency a state with no enabled administrator is still theoretically reachable: a process stalled between its two writes for more than the 5 minute grace period of a removal, while a rebuild runs and the last other administrator is demoted. Direct writes to `users` outside unpub are also only repaired by the next rebuild. To recover, run `unpub admin set-role --email <address> --role admin` (followed by `unpub admin enable` if that account is disabled) or `unpub admin create-user --email <address> --role admin` from the command line, neither of which needs an existing administrator.

### HTTP API

JSON endpoints under `/webapi`, for scripts and the upcoming web UI. Errors look like `{"error": {"code": "...", "message": "..."}}`, with status 400, 401, 403, 404, 409 or 429.

| Endpoint | Description |
| --- | --- |
| `POST /webapi/login` | `{email, password}`. Sets the session cookie and returns the user and `csrfToken`. |
| `POST /webapi/logout` | Ends the session. |
| `GET /webapi/me` | The current user and scopes, and `csrfToken` for a session. |
| `POST /webapi/me/password` | Session only: `{currentPassword, newPassword}`. Ends the other sessions of the user. |
| `GET`, `POST /webapi/tokens` | List or create your own tokens. Create takes `{name, scopes?, expiresIn?}` and returns the `secret` once. A token cannot create a token with more scopes or a later expiry than its own. |
| `DELETE /webapi/tokens/<id>` | Revoke your own token. An administrator logged in with a password can revoke any. A token or `auth.bootstrapToken` can only revoke tokens of its own user: revoking another user's token answers 403 `session_required` to an administrator's token and 404 to anyone else's. |
| `GET`, `POST /webapi/users` | Administrators: list users, or with a session create one from `{email, role, displayName?, password?}`. |
| `PATCH /webapi/users/<id>` | Administrators, session only: change `role`, `disabled` or `displayName`. Answers 503 if another change to an administrator stays in progress. |
| `POST /webapi/users/<id>/password` | Administrators, session only: `{password}`. |

After 10 failed attempts within 15 minutes, for one email or one client address, login answers 429 with `Retry-After`. The count is kept per process, so several instances each allow their own attempts. Each process tracks up to 50 000 addresses and emails. When that is full it forgets only expired counters and those below half the limit, and if that frees nothing it answers 429 to addresses and emails it does not know yet and logs a warning. Sessions last 24 hours.

Logins, token and user changes, publishes, uploader changes, retractions and discontinuations are recorded in the `audit` collection.

## Pub API compatibility

`GET /api/packages/<name>` and `GET /api/packages/<name>/versions/<version>` answer in the format current `dart pub` and `flutter pub` clients use.

| Field | Where | Description |
| --- | --- | --- |
| `archive_url` | version | Where to download the archive. |
| `archive_sha256` | version | Lowercase hex SHA-256 of the stored archive. Absent for a version without a recorded hash, until `unpub migrate` has backfilled it. |
| `pubspec`, `version` | version | The pubspec, and its version. |
| `published` | version | When it was published, ISO-8601 in UTC. |
| `retracted` | version | `true` for a retracted version, otherwise absent. |
| `name`, `versions` | package | The package and all its versions. |
| `latest` | package | The highest version that is neither a prerelease nor retracted. If there is none, the highest prerelease that is not retracted. If every version is retracted, the highest version anyway. |
| `isDiscontinued` | package | Whether the package is discontinued. |
| `replacedBy` | package | The suggested replacement, only when set. |

`GET /api/packages/<name>/advisories` answers `{"advisories": [], "advisoriesUpdated": null}` for a local package.

Responses can be cached:

| Response | `ETag` | `Cache-Control` in `public` mode | `Cache-Control` in `authenticated` mode |
| --- | --- | --- | --- |
| Listing | Weak, changes with the package | `public, max-age=60` | `private, no-store` |
| Archive | Strong, from the SHA-256, when known | `public, max-age=31536000, immutable`, or `public, max-age=60` with `publish.requireVersionBump: false`, because the archive can then be replaced | `private, no-store` |

A matching `If-None-Match` answers 304. Downloads are counted only for `dart pub` and `flutter pub`, and a 304 or `HEAD` is not a download. Besides the package total and the daily `stats`, each version has its own count in the `version_stats` collection. `/webapi/package/<name>/<version>` reports them as `downloads: {"version": n, "package": n}`, and each entry of its `versions` has `downloads` and `uploader`. `/webapi/packages` reports `downloads` per package.

## Retraction and discontinued

Uploaders of a package and administrators can change these, with a credential that has the `publish` scope. API tokens work, so CI can use them. Sessions need their CSRF token. Each change is audited.

| Endpoint | Description |
| --- | --- |
| `POST /api/packages/<name>/versions/<version>/retract` | Retract a version. Encode `+` in the version as `%2B`. |
| `POST /api/packages/<name>/versions/<version>/unretract` | Restore a retracted version. |
| `PUT /api/packages/<name>/discontinue` | `{"isDiscontinued": true, "replacedBy": "<name>"}`, with `replacedBy` optional, or `{"isDiscontinued": false}`. `replacedBy` must be a valid package name and need not exist on this server. |

A retracted version stays downloadable, so a project with it in its lockfile still resolves, but new resolutions avoid it and it is left out of `latest`. If every version of a package is retracted, `latest` is the highest version anyway, the same as pub.dev, because a listing has to name one. The only version of a package can be retracted too, and then stays `latest`. A non-administrator can retract only within `publish.retractionWindow` of publishing, 7 days by default, and is answered 403 after that. The window does not limit `unretract`.

A discontinued package keeps serving everything, with the flag set. `/webapi/packages` leaves discontinued packages out unless called with `?discontinued=true`. `/webapi/packages` and `/webapi/package/<name>/<version>` include the flags, and the latter `discontinuedAt`.

## Publishing policies

Set under `publish`. A violation goes back through `dart pub publish`, with a message naming the setting. The `uploadValidator` callback of an embedded `App` runs after them.

| Key | Environment variable | Default | Description |
| --- | --- | --- | --- |
| `publish.allowedNamePrefixes` | `UNPUB_PUBLISH_ALLOWED_NAME_PREFIXES` | any name | Package names must start with one of these. Applies to every publish, including new versions of existing packages. A YAML list, or comma separated in the environment. |
| `publish.maxArchiveBytes` | `UNPUB_PUBLISH_MAX_ARCHIVE_BYTES` | `104857600` (100 MiB) | Largest archive accepted. A larger one is refused without being kept in memory. A reverse proxy needs a matching limit, such as `client_max_body_size` in nginx. |
| `publish.maxUnpackedBytes` | `UNPUB_PUBLISH_MAX_UNPACKED_BYTES` | `536870912` (512 MiB) | Largest size an archive may inflate to. Enforced while inflating, so a compression bomb is stopped at the limit. |
| `publish.requiredFiles` | `UNPUB_PUBLISH_REQUIRED_FILES` | none | Files the archive must hold at its root, matched ignoring case, such as `README.md`, `CHANGELOG.md` and `LICENSE`. They must be regular files. A symbolic or hard link does not count. |
| `publish.rejectOlderThanLatest` | `UNPUB_PUBLISH_REJECT_OLDER_THAN_LATEST` | `false` | Refuse a version lower than the highest version not retracted, prereleases included. |
| `publish.requireVersionBump` | `UNPUB_PUBLISH_REQUIRE_VERSION_BUMP` | `true` | Refuse a version that already exists. When `false`, publishing an existing version replaces it, including any retraction. Clients that recorded its hash then fail. Archives are then only cached for 60 seconds. |
| `publish.retractionWindow` | `UNPUB_PUBLISH_RETRACTION_WINDOW` | `7d` | How long after publishing a non-administrator may retract, in `s`, `m`, `h`, `d` or `w`. `0` is unlimited. |
| `publish.uploadTimeout` | `UNPUB_PUBLISH_UPLOAD_TIMEOUT` | `10m` | How long storing an uploaded archive may take. Longer answers a retryable 503. Must be under 15 minutes, the time a publish keeps its version reserved. |

While one version is being published, another upload of that version is refused with "version is being published by another request", also from another server instance on the same MongoDB. The claim lives in the `upload_reservations` collection for as long as the archive is written. If a server dies while holding one, the version stays blocked until the claim expires, 15 to 16 minutes later.

The claim is renewed once halfway through `publish.uploadTimeout` if the write is still running. A publish writes its archive first, as an immutable object, and only then the metadata, so a publish that stalled past its claim can neither overwrite another one's archive nor leave a version without one. See [Storage layout](#storage-layout).

## Storage layout

The storage directory, or the bucket under the same keys, holds:

| Path | What it is |
| --- | --- |
| `<name>/<name>-<version>-<sha256>.tar.gz` | A published archive, an immutable object named by the digest of its bytes. |
| `upstream/<name>/<name>-<version>-<sha256>.tar.gz` | A proxied archive, also immutable. |
| `<name>-<version>.tar.gz`, or `<name>/<name>-<version>.tar.gz` in S3 | A published archive from before objects existed. Still served, and never written any more. |
| `.unpub-tmp/` | Reserved for temporary files. No archive may be stored there. |

- **The `archiveLayout` of a version says where its archive is.** `digest`, set by every new upload and replacement, means the object named by its `sha256`, and a missing object is a 404 with an error naming the digest, never the legacy file: those bytes belong to a different archive. `legacy`, set by `unpub migrate` on what it hashes in place, means the legacy path, served as it is with its recorded hash as `ETag`. A version without the field is `legacy` if it has no hash, and otherwise `legacy` only if its digest object does not exist and the legacy file does and hashes to the recorded digest; a legacy file with other bytes is a 404, because it belongs to an earlier archive of that version.
- **A publish writes the object first, then the metadata.** Adding a version is conditional on the version not existing, and replacing one with `publish.requireVersionBump: false` is a compare-and-set on its previous `sha256`, so of two concurrent publishes one wins and the other reports the failure. Nothing changes for a client until the metadata is written. A publish that loses or fails never deletes anything, and neither does one that crashes in between: what is left is only an object nothing refers to, for reclamation to remove.
- **Every write and deletion of an object holds the lock of its digest,** a document in the `object_locks` collection: a publish from before writing the object until after the metadata and a check that the object is still there, the proxy around storing an archive and recording it, and reclamation around its decision and its delete. If a publish cannot get the lock within `publish.uploadTimeout` it fails and can be retried. The lock lasts 2 minutes and is renewed while held, on the clock of the database, so the lock of a holder that crashed expires by itself.
- **Temporary files** are written to `.unpub-tmp/` and renamed into place. With S3 the archive is simply put at its key, and `upstream.mode: proxy` spools to `.unpub-tmp/` in the system temp directory.
- **Reclamation** runs at startup and once an hour, and logs its counts. It deletes files in `.unpub-tmp/` older than an hour, and nothing outside it, whatever it is called. It then deletes objects in the two layouts above that are older than an hour and named by no version and no `upstream_archives` record. Each candidate is decided under the lock of its digest: its age, its references and its hash are checked again, and if the lock is busy it waits for the next run. So reclamation never deletes anything younger than an hour, and never while a lock is live.

When using unpub as a library, `FileStore(getFilePath:)` and the `getObjectPath` of `S3Store` still say where legacy archives live, with the signature `(name, version)`. The new optional `FileStore(getObjectPath:)` and `S3Store(getDigestObjectPath:)`, with the signature `(name, version, sha256)`, say where objects live. Objects in a custom layout cannot be listed, so reclamation leaves them alone. Any of these that answers a path inside `.unpub-tmp/` is rejected when the store is created.

## Upstream proxy

By default a package that does not exist locally is redirected to `upstream.url`. With `upstream.mode: proxy` this server fetches it instead, and keeps a copy, so that builds keep working when the upstream is unreachable.

| Key | Environment variable | Default | Description |
| --- | --- | --- | --- |
| `upstream.url` | `UNPUB_UPSTREAM_URL` | `https://pub.dev` | The upstream registry. Must not contain credentials in `proxy` mode. |
| `upstream.mode` | `UNPUB_UPSTREAM_MODE` | `redirect` | `redirect` or `proxy`. |
| `upstream.cacheTtl` | `UNPUB_UPSTREAM_CACHE_TTL` | `10m` | How long metadata is served without asking the upstream. `0` asks every time. Archives never expire. |
| `upstream.allowlist` | `UNPUB_UPSTREAM_ALLOWLIST` | any package | The only packages proxied. Others answer 404 and can be published here. Only applies in `proxy` mode, and the server warns at startup if it is set in `redirect` mode. |
| `upstream.timeout` | `UNPUB_UPSTREAM_TIMEOUT` | `30s` | How long the upstream may stay silent during a request, and how long a first download may wait for a fetch slot. |
| `upstream.allowedArchiveHosts` | `UNPUB_UPSTREAM_ALLOWED_ARCHIVE_HOSTS` | none | Hosts besides that of `upstream.url` that archives and redirects may go to. Host names only, without a scheme or port. |
| `upstream.requireSha256` | `UNPUB_UPSTREAM_REQUIRE_SHA256` | `true` | Answer 502 for an archive the upstream gives no `archive_sha256` for. When `false` it is served and cached unverified, with a warning and a weak `ETag`. A malformed hash is always a 502. |
| `upstream.maxArchiveBytes` | `UNPUB_UPSTREAM_MAX_ARCHIVE_BYTES` | `268435456` (256 MiB) | Largest archive fetched. Enforced while streaming, and a larger one answers 502 and leaves nothing behind. |
| `upstream.maxConcurrentFetches` | `UNPUB_UPSTREAM_MAX_CONCURRENT_FETCHES` | `4` | How many archives are fetched at once. Other first downloads wait up to `upstream.timeout`, then answer 503. Downloads of one archive share a single fetch. |
| `upstream.allowPublishWhenUnavailable` | `UNPUB_UPSTREAM_ALLOW_PUBLISH_WHEN_UNAVAILABLE` | `false` | Accept a new package name, with a warning, when the upstream cannot say whether it has it. Such a name shadows the upstream package from then on. |

A local package always wins over the upstream. For the others:

- **Metadata** is kept in the `upstream_cache` collection and served for `cacheTtl`, then revalidated. Archive URLs are rewritten to this server. Entries expire on their own 7 days after they go stale.
- **Archives** are immutable objects named by the digest of their bytes, `upstream/<name>/<name>-<version>-<sha256>.tar.gz` on disk and under the same key in S3. The first download streams the whole archive to a temporary file while hashing it, in `.unpub-tmp/` in the storage directory, or in the system temp directory for S3 (`TMPDIR`, which has to be writable and have room for the largest archive), checks it against `archive_sha256`, stores it and then answers, so the client waits for the full download once. A mismatch is discarded and answered with 502. Later downloads come from storage.
- **Integrity:** the record in the `upstream_archives` collection is the only pointer to an object: what is served is the object it names, and its digest is the `ETag`, so bytes and hash cannot disagree, also with several instances on one storage. Without a record, or without the object it names, the archive counts as not stored and is fetched again. If the listing later names another hash, the object is forgotten and fetched again, and a failed refetch answers 502. An object no record points to any more is reclaimed, see [Storage layout](#storage-layout).
- **Archive locations** must have the scheme, host and port of `upstream.url`, or a host in `upstream.allowedArchiveHosts`. Redirects are followed by hand, at most three, with each hop held to the same rule, and a hop from https to http is refused. pub.dev serves archives from its own host, so it needs no entry.
- **Memory:** an archive is never held in memory, whatever its size. Metadata responses are read into memory, up to 64 MiB each, and `maxConcurrentFetches` does not limit them. On a proxy reachable by the public, set an `allowlist`, because every distinct package and version requested otherwise costs an upstream fetch and storage for as long as archives are kept.
- **Upstream failures** answer 502 with a JSON error for metadata, also when a stale copy exists, and for archives that are not stored yet. Archives already stored keep being served.
- **Publishing** a new name needs a definitive answer. A fresh listing refuses the name. Otherwise the upstream is asked: a 200 refuses it, a 404 accepts it, and anything else answers 503 with "upstream registry unavailable, cannot verify that <name> is free, try again", unless `upstream.allowPublishWhenUnavailable` is on. During an outage `dart pub publish` usually stops earlier, at its own listing request, with a 502.
- **Reading** follows `auth.readAccess`, so clients need their token for proxied packages in `authenticated` mode. Client credentials are never sent to the upstream.
- Proxied downloads are not counted, and proxied packages do not appear in `/webapi/packages` or the web UI.

## Running from source

Requires the Dart SDK and MongoDB 3.6 or later. The server and `unpub admin` log the version they connect to and stop with a clear message on anything older.

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
| `unpub migrate [--dry-run] [--rerun step] [--config path]` | Apply pending data migrations, or list what would change. `--rerun 0002` runs only that step again. |
| `unpub admin ...` | Manage users and tokens. See [Administrators](#administrators). |

## Configuration

Settings are resolved in this order, with later ones winning: built-in defaults, the YAML file, environment variables, then the `--host` and `--port` flags. Startup fails with a list of every problem if the configuration is invalid.

The file is `unpub.yaml` in the working directory, or the path given with `--config`. See [unpub.example.yaml](unpub.example.yaml) for a commented example.

Any key can be set through a variable named `UNPUB_<SECTION>_<KEY>`. CamelCase keys take underscores, so `server.publicUrl` is `UNPUB_SERVER_PUBLIC_URL`.

| Key | Environment variable | Default | Description |
| --- | --- | --- | --- |
| `server.host` | `UNPUB_SERVER_HOST` | `0.0.0.0` | Listen address. |
| `server.port` | `UNPUB_SERVER_PORT` | `4000` | Listen port. |
| `server.publicUrl` | `UNPUB_SERVER_PUBLIC_URL` | derived from the request | External origin, used in archive and upload URLs. Set it behind a reverse proxy. `https` also marks the session cookie `Secure`. |
| `server.trustForwardedFor` | `UNPUB_SERVER_TRUST_FORWARDED_FOR` | `false` | Take the client address for the login limit and the audit log from the last entry of `X-Forwarded-For`. Only enable behind a proxy that sets it. |
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
| `storage.s3.sessionToken` | `UNPUB_STORAGE_S3_SESSION_TOKEN` | | Session token for `storage.s3.accessKey`. Keys from the environment use `AWS_SESSION_TOKEN` instead. |
| `upstream.url` | `UNPUB_UPSTREAM_URL` | `https://pub.dev` | Where packages not found locally come from. See [Upstream proxy](#upstream-proxy) for the other `upstream.*` keys. |
| `publish.*` | `UNPUB_PUBLISH_*` | | See [Publishing policies](#publishing-policies). |
| `auth.admin.email` | `UNPUB_AUTH_ADMIN_EMAIL` | | First administrator, created when there are no users. Set together with the password. |
| `auth.admin.password` | `UNPUB_AUTH_ADMIN_PASSWORD` | | Password of that administrator, at least 8 characters. Prefer the environment. |
| `auth.readAccess` | `UNPUB_AUTH_READ_ACCESS` | `public` | `public`, or `authenticated` to require a token or session on every route except `/healthz`, `/readyz` and login. |
| `auth.bootstrapToken` | `UNPUB_AUTH_BOOTSTRAP_TOKEN` | | Deprecated. Static Bearer token that acts as an administrator. |
| `auth.bootstrapEmail` | `UNPUB_AUTH_BOOTSTRAP_EMAIL` | `admin@localhost` | Email of the `auth.bootstrapToken` identity, and the uploader recorded for its publishes. |
| `auth.readTokens` | `UNPUB_AUTH_READ_TOKENS` | | Deprecated. Static Bearer tokens that act as readers. A YAML list, or comma separated in the environment. |
| `logging.level` | `UNPUB_LOGGING_LEVEL` | `info` | `fine`, `info`, `warning`, `severe` and other `package:logging` levels, or `off`. |
| `logging.format` | `UNPUB_LOGGING_FORMAT` | `text` | `text` or `json`. |

Without `storage.s3.accessKey`, S3 credentials come from the standard AWS variables or the ECS task role. Credentials are never combined across these sources.

### Upgrading from 2.x

- The `--database` and `--proxy-origin` flags and the `proxy-origin` header are replaced by `mongo.uri` and `server.publicUrl`.
- Google sign-in is gone. The environment variables map as follows:

  | 2.x | 3.x |
  | --- | --- |
  | `UPLOAD_TOKEN` | `auth.bootstrapToken` |
  | `UPLOAD_EMAIL` | `auth.bootstrapEmail` |
  | `ALLOWED_TOKENS` | `auth.readAccess: authenticated` and `auth.readTokens` |

- A registry that set `ALLOWED_TOKENS` was private. It becomes world-readable unless you set `auth.readAccess: authenticated`, which is not the default.
- The embedded web UI cannot send tokens, so it is unusable in `authenticated` mode, as it was with `ALLOWED_TOKENS`, until the new UI replaces it. Badges under `/badge/...` need a token in that mode too, so public badge images stop working.
- A package without an `uploaders` list can now only be changed by an administrator.
- Accounts: run `unpub migrate` once. It creates a placeholder `publisher` for every email in existing `uploaders`, and an `admin` for `auth.bootstrapEmail` if it appears there. Check first with `unpub migrate --dry-run`. Placeholders cannot log in, so give them a password with `unpub admin set-password` or a token with `unpub admin create-token`.
- Run `unpub migrate` after creating your first administrator, or use `unpub admin create-user` afterwards: `auth.admin.*` is ignored once any user exists.
- `auth.bootstrapToken` and `auth.readTokens` keep working but are deprecated. Replace them with personal tokens. Neither these nor personal tokens can manage users over HTTP, so use `unpub admin` or log in.
- Package names must now match `[a-z_][a-z0-9_]*` and be at most 64 characters long. A stored package with any other name is no longer reachable.
- Archive hashes: `unpub migrate` step `0002_version_sha256` records the SHA-256 of every stored archive, so that existing versions get `archive_sha256`. Check first with `unpub migrate --dry-run`. An archive missing from storage is skipped with a warning, and that version keeps being served without a hash. Once the archive is back, `unpub migrate --rerun 0002` hashes the versions still missing one. Run it with the same `storage` settings as the server.
- The `latest` field of a listing now skips retracted versions, and the `/webapi` views use the same rule. Listings have new fields, and existing clients ignore what they do not know.
- MongoDB documents and the archive layout are unchanged apart from new optional fields. Archives stay in `unpub-packages` by default. Accounts live in the new collections `users`, `tokens`, `sessions`, `audit`, `admin_set` and `migrations`. Phase 3 adds `version_stats`, `upstream_cache`, `upstream_archives` and `upload_reservations`.

### Behind a reverse proxy

Set `server.publicUrl` to the external origin, and use HTTP/1.1 towards unpub:

```nginx
proxy_http_version 1.1;
proxy_set_header Host $host;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
client_max_body_size 100m;
```

Also set `server.trustForwardedFor: true`, or the login limit and the audit log see only the address of the proxy, and one user's failures would lock out everyone.

## Operations

| Endpoint | Description |
| --- | --- |
| `GET /healthz` | Returns 200 while the process is up. |
| `GET /readyz` | Checks MongoDB and that storage accepts writes, by writing and deleting a probe (on S3, under `.unpub/`). Returns 200, or 503 with JSON details. |

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

  final metaStore = unpub.MongoStore(db);
  await metaStore.ensureIndexes();

  final app = unpub.App(
    metaStore: metaStore,
    packageStore: unpub.FileStore('./unpub-packages'),
    authenticator: const unpub.StaticTokenAuthenticator(
      bootstrapToken: 'a-long-random-token',
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

`PublishPolicy` applies the `publish` settings, and `UpstreamProxy` turns on proxy mode. `MetaStore`, `PackageStore`, `Authenticator` and `AuditStore` can each be replaced by your own implementation. The account endpoints are added by passing an `AccountApi`. `S3Store` and `FileStore` are included.

`ensureIndexes` creates the unique indexes that concurrent publishes rely on, and throws if `packages` already holds a name twice. To get reclamation as `unpub serve` does it, start a `TemporaryReclaimer` with `MongoArchiveReferences` too, which shares the `object_locks` of `MongoStore`.

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
