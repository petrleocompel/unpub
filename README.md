# Unpub

Unpub is a self-hosted private Dart Pub server for teams, with a simple web interface to search and view package information. It is a single binary that stores metadata in MongoDB and package archives on disk or in S3.

> **This is a modernization in progress.** User accounts, roles, personal API tokens, publishing policies, an upstream proxy, a server-rendered web UI with an admin panel, and the server side of a single-page web client are in place. What comes next is in [docs/ROADMAP.md](docs/ROADMAP.md).

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

Reading is public by default, and only publishing and uploader management need a token. To make the registry private, set `auth.readAccess: authenticated`. Every route except `/healthz`, `/readyz`, the login form `/login` with the stylesheet and script under `/static/`, and `POST /webapi/login` then needs a token or session, which `dart pub get` provides once the token is added with `dart pub token add`. The web UI works in that mode: a browser asking for a server-rendered page is sent to its login page and reads with its session cookie once logged in, and the shell and files of the [web client](#web-client), as well as `GET /webapi/config` and `GET /webapi/openapi.yaml`, stay open so that the client can show its own login. API clients, `/api`, `/webapi` and archives still answer 401 without a token, even to a browser. Badges under `/badge/...` answer 401 as well, so shields.io and similar scrapers cannot fetch them from a private registry without a token.

Dart clients only send tokens over HTTPS, except to localhost, so deploy behind TLS.

## Authentication

### Roles

| Role | May |
| --- | --- |
| `admin` | Everything: manage users, publish to any package, manage the uploaders of any package, retract or discontinue any package, delete versions and packages, transfer ownership, manage webhooks and read the audit log. |
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

JSON endpoints under `/webapi`, used by the [web client](#web-client) and by scripts. The contract is [docs/openapi.yaml](docs/openapi.yaml) (OpenAPI 3.1), which every server also serves at `GET /webapi/openapi.yaml`. Errors look like `{"error": {"code": "...", "message": "..."}}`, with status 400 (`invalid_request`, the only validation code), 401 (`unauthorized`, or `invalid_credentials` for a failed login), 403 (`forbidden`, `insufficient_scope`, `session_required`, `csrf_failed`, or `invalid_credentials` for a wrong current password), 404 (`not_found`), 409 (`conflict`, `last_admin`, `admin_change_in_progress`), 429 (`rate_limited`, with `Retry-After`), 500 (`server_error`), 502 (`bad_gateway`) or 503 (`unavailable`); `too_large` (413) is reserved, a JSON body over 64 KiB answers 400. The spec lists when each applies. List routes take a one-based `page`, at most 100000, and a `size`, at most 100 unless said otherwise, and answer `{"items": [...], "page": 1, "size": 20, "total": 42}`. Except on the audit log, which refuses them with 400, values out of range are moved into it, so a page past the end is empty, not an error.

**CSRF.** A request authenticated by the session cookie that is not GET, HEAD or OPTIONS must carry the session's CSRF token in the `X-CSRF-Token` header, or, for a form post, the `csrf_token` field. Without it, or with a wrong one, it is refused with 403 and the code `csrf_failed`, and nothing changes. The token is in the answers of `POST /webapi/login` and `GET /webapi/me`. This applies to every change: the `/webapi` routes and the package management routes under `/api/packages` alike. Requests with `Authorization: Bearer` need no CSRF token.

| Endpoint | Description |
| --- | --- |
| `GET /webapi/config` | Open in every read mode: `version`, `publicUrl`, `readAccess`, `accounts`, `upstream {url, mode}`, `features {metrics, webhooks, spa, classic}` and `ui {mode, basePath, classicPath}`. No secrets. |
| `GET /webapi/openapi.yaml` | This API, as OpenAPI 3.1. Open in every read mode. |
| `POST /webapi/login` | `{email, password}`. Sets the session cookie (`HttpOnly`, `SameSite=Lax`, `Path=/`, and `Secure` when `server.publicUrl` is https) and returns the `user` and `csrfToken`. |
| `POST /webapi/logout` | Ends the session. |
| `GET /webapi/me` | The current user and scopes, and `csrfToken` for a session. |
| `POST /webapi/me/password` | Session only: `{currentPassword, newPassword}`. Ends the other sessions of the user. |
| `GET`, `POST /webapi/tokens` | List (paged, newest first) or create your own tokens. Create takes `{name, scopes?, expiresIn?}` and returns the `secret` once. A token cannot create a token with more scopes or a later expiry than its own. |
| `DELETE /webapi/tokens/<id>` | Revoke your own token. An administrator logged in with a password can revoke any. A token or `auth.bootstrapToken` can only revoke tokens of its own user: revoking another user's token answers 403 `session_required` to an administrator's token and 404 to anyone else's. |
| `GET`, `POST /webapi/users` | Administrators: list users by email, paged, `q` searching the email and display name, or with a session create one from `{email, role, displayName?, password?}`. |
| `PATCH /webapi/users/<id>` | Administrators, session only: change `role`, `disabled` or `displayName`. Answers 409 `admin_change_in_progress` if another change to an administrator stays in progress. |
| `POST /webapi/users/<id>/password` | Administrators, session only: `{password}`. |
| `GET /webapi/v2/packages` | The package list: `q`, `sdk` (`dart` or `flutter`), `discontinued` (`true` to include them), `sort` (`relevance`, `downloads`, `updated`, `name`), `page`, `size`, with the semantics of the package list page. Items have `name`, `latest`, `description`, `updatedAt`, `downloads`, `isDiscontinued`, `replacedBy`, `isFlutter` and `private`. |
| `GET /webapi/packages` | Deprecated, for scripts: the former list, `{"data": {"count", "packages"}}`, with a zero-based `page`. |
| `GET /webapi/package/<name>`, `GET /webapi/package/<name>/<version>` | `{"data": ...}`: a package at its latest or the given version (or `latest`), with `readmeHtml` and `changelogHtml` rendered and sanitized as on the package page, `dependencies` and `devDependencies` as `{name, constraint, hosted, local}`, `environment {sdk, flutter}`, `platforms`, `uploaders`, `uploader`, `published`, `retracted`, `retractedAt`, `isDiscontinued`, `replacedBy`, `archiveSha256`, `downloads {version, package}`, `private`, the pubspec links and every version as `{version, published, uploader, retracted, prerelease, downloads}`, highest first. |
| `GET /webapi/package/<name>/stats` | `{name, total, recent, days: [{day, count}], versions: [{version, downloads}]}`: the last 30 days, zero-filled, and every version, most downloaded first. |
| `GET /webapi/settings` | Administrators with the `read` scope: the effective configuration of `/admin/settings`, secrets redacted, by section, each key with the environment variable that sets it. |
| `GET /webapi/admin/overview` | Administrators with the `read` scope: counts of packages, versions, users and webhooks, the storage size as `/metrics` measures it, publishes and failed webhook deliveries of the last 24 hours, the last 10 publishes and the `/readyz` checks. |
| `GET /webapi/audit` | Administrators with the `read` scope: the audit log, see [Audit log](#audit-log). |
| `GET`, `POST /webapi/webhooks`, and `/webapi/webhooks/<id>...` | Administrators: manage webhooks, see [Webhooks](#webhooks). |

The package management routes under `/api/packages/<name>` (retract, unretract, discontinue, uploaders, owner, delete) are described in [Retraction and discontinued](#retraction-and-discontinued) and [Package management](#package-management) and answer `{"success": {"message": ...}}`.

After 10 failed attempts within 15 minutes, for one email or one client address, login answers 429 with `Retry-After`. The count is kept per process, so several instances each allow their own attempts. Each process tracks up to 50 000 addresses and emails. When that is full it forgets only expired counters and those below half the limit, and if that frees nothing it answers 429 to addresses and emails it does not know yet and logs a warning. Sessions last 24 hours.

Logins, token and user changes, publishes, deletions, uploader changes, retractions, discontinuations and webhook changes are recorded in the `audit` collection, see [Audit log](#audit-log).

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

A matching `If-None-Match` answers 304. Downloads are counted only for `dart pub` and `flutter pub`, and a 304 or `HEAD` is not a download. Besides the package total and the daily `stats`, shown on `/packages/<name>/stats`, each version has its own count in the `version_stats` collection. `/webapi/package/<name>/<version>` reports them as `downloads: {"version": n, "package": n}`, and each entry of its `versions` has `downloads` and `uploader`. `/webapi/packages` reports `downloads` per package.

## Retraction and discontinued

Uploaders of a package and administrators can change these, with a credential that has the `publish` scope. API tokens work, so CI can use them. Sessions need their CSRF token. Each change is audited.

| Endpoint | Description |
| --- | --- |
| `POST /api/packages/<name>/versions/<version>/retract` | Retract a version. Encode `+` in the version as `%2B`. |
| `POST /api/packages/<name>/versions/<version>/unretract` | Restore a retracted version. |
| `PUT /api/packages/<name>/discontinue` | `{"isDiscontinued": true, "replacedBy": "<name>"}`, with `replacedBy` optional, or `{"isDiscontinued": false}`. `replacedBy` must be a valid package name and need not exist on this server. |

A retracted version stays downloadable, so a project with it in its lockfile still resolves, but new resolutions avoid it and it is left out of `latest`. If every version of a package is retracted, `latest` is the highest version anyway, the same as pub.dev, because a listing has to name one. The only version of a package can be retracted too, and then stays `latest`. A non-administrator can retract only within `publish.retractionWindow` of publishing, 7 days by default, and is answered 403 after that. The window does not limit `unretract`.

A discontinued package keeps serving everything, with the flag set. `/webapi/packages` leaves discontinued packages out unless called with `?discontinued=true`. `/webapi/packages` and `/webapi/package/<name>/<version>` include the flags, and the latter `discontinuedAt`.

## Package management

Administrators can delete versions and packages and transfer a package to another user. Uploaders keep adding and removing uploaders as before.

| Endpoint | Who | Description |
| --- | --- | --- |
| `POST /api/packages/<name>/uploaders` | uploader or admin | Form field `email`: add an uploader. |
| `DELETE /api/packages/<name>/uploaders/<email>` | uploader or admin | Remove an uploader. |
| `PUT /api/packages/<name>/owner` | admin | `{"email": "<address>"}`: make that user the only uploader. With user accounts the email must belong to an existing user, otherwise 404. |
| `DELETE /api/packages/<name>/versions/<version>` | admin | Delete one version, its download counts and its archive. Encode `+` as `%2B`. |
| `DELETE /api/packages/<name>` | admin | Delete the package with every version, archive and download count. |

They need a credential with the `publish` scope: an anonymous request gets 401, a reader, a `read` token or an uploader who is not an administrator gets 403. The admin page `/admin/packages/<name>` offers the same: a confirmation page before deleting a version, a form that needs the package name typed before deleting the package, and a transfer form that leads to a confirmation page. None of them depends on JavaScript: a post without the confirmation is refused with 400 and changes nothing. Both go through the same code, so they apply the same rules and are audited alike (`version.deleted`, `package.deleted`, `uploader.transferred`).

- The last version of a package cannot be deleted, which answers 409 with a hint to delete the package. `latest` is computed from what is left.
- A package mirrored from the upstream (`private: false`) cannot be deleted or transferred here (409). An unknown package or version is a 404.
- A deleted version can be published again, unlike on pub.dev, as a new upload with a new hash. Clients that locked the old hash then fail to verify it, so prefer retracting.
- **After the deletion.** Once the version or the package document is gone, the deletion counts as done. Removing the download counts, stale reservations and archives is then best effort: a failure is logged and recorded in `details.cleanupError` of the audit event, the webhook event is still sent and the client still gets success. What is left is stale counters and, at worst, an orphan archive for reclamation.
- **Archives.** An archive named by its digest is deleted under the lock of that digest in `object_locks`, and only if no other version and no `upstream_archives` record names the same digest. An archive that cannot be deleted at once, for example because its lock stays busy for 30 seconds, is left to the hourly reclamation, which removes it as an orphan. An archive at the legacy path is deleted with its version.
- **Racing a publish.** A deletion reserves each version it deletes in `upload_reservations`, as `dart pub publish` does, so a publish of that version and the deletion cannot overlap: whichever comes second gets 409, or the retryable publish error. A package document is deleted only while it still holds exactly the reserved versions. A version published in the meantime makes the deletion start over and take that version with the rest, up to three times. A publish that starts after the package document is gone creates a new package of that name, owned by its uploader, as it would after the deletion. Stale reservations of the package go with it.

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

## Audit log

Every change is recorded in the `audit` collection with the same fields:

| Field | Description |
| --- | --- |
| `at` | When, UTC. |
| `action` | What happened, see below. |
| `actor` | The email of whoever acted, `system` for the server and `unpub admin`, or the email a failed login tried. |
| `actorKind` | How the actor proved who it is: `session`, `apiToken`, `staticToken`, `password` (a login), `anonymous` (a failed login) or `system`. |
| `token` | The prefix of the API token that acted, when one did. |
| `ip` | The client address, from `X-Forwarded-For` with `server.trustForwardedFor`. |
| `package`, `version` | What a package event is about. |
| `target` | The user (email), token (`token:<prefix>`) or webhook (`webhook:<id>`) acted on. |
| `details` | What changed, such as the old and new role, the removed uploader or the deleted versions. Never a password or secret. |

Actions: `package.published`, `version.retracted`, `version.unretracted`, `version.deleted`, `package.discontinued`, `package.continued`, `package.deleted`, `uploader.added`, `uploader.removed`, `uploader.transferred`, `user.created`, `user.updated` (display name), `user.role_changed`, `user.disabled`, `user.enabled`, `user.password_set`, `user.login`, `user.login_failed`, `token.created`, `token.revoked`, `webhook.created`, `webhook.updated`, `webhook.secret_rotated`, `webhook.deleted` and `webhook.redelivered`. Events written by earlier 3.0.0 development builds have `target: "<name>@<version>"` for package events, an `actor` of `token:<prefix>` for token requests and `user.updated` for role and state changes; they are kept as they are.

`GET /webapi/audit` lists events newest first, for an administrator with the `read` scope:

| Parameter | Description |
| --- | --- |
| `action` | One action. |
| `actor` | An email, or `token:<prefix>` for everything one token did. |
| `package` | One package. |
| `from`, `to` | ISO 8601 dates or times, `from` included and `to` excluded. A date without a time means that day in UTC, and `to` then includes the whole day. |
| `page`, `size` | One-based page, and up to 200 events per page, 50 by default. |

```json
{"items": [{"at": "2026-11-10T09:12:00.000Z", "action": "version.deleted", "actor": "admin@example.com", "actorKind": "session", "token": null, "package": "my_package", "version": "1.2.0", "target": null, "ip": "203.0.113.9", "details": {"sha256": "…", "archiveDeleted": true}}], "page": 1, "size": 50, "total": 1}
```

The admin page `/admin/audit` shows the same with a filter form and pages, and the admin page of each package links to its events. The queries use indexes on `at` and on `package`, `actor` and `action` with `at`.

`audit.retentionDays` keeps events for that many days through a TTL index on `at`, which MongoDB applies about once a minute. The server creates, changes or drops the index at every start to match the setting, and `0`, the default, keeps every event.

## Webhooks

Webhooks tell other systems, such as CI or a chat bot, when a package changes. Administrators manage them on `/admin/webhooks` or through the API, and each change is audited. Delivery is switched off for the whole server with `webhooks.enabled: false`.

| Event | When |
| --- | --- |
| `package.published` | A version was published, `data` has `uploader` and `sha256`. |
| `version.retracted`, `version.unretracted` | A version was retracted or restored. |
| `package.discontinued`, `package.continued` | The discontinued flag was set, with `data.replacedBy` when given, or cleared. Repeating the same state is not an event. |
| `version.deleted` | A version was deleted, `data` has its `sha256`. |
| `package.deleted` | A package was deleted, `data.versions` lists its versions. |

Each delivery is a `POST` of a JSON body:

```json
{
  "id": "673071c9a1b2c3d4e5f60718",
  "event": "package.published",
  "at": "2026-11-10T09:12:00.000Z",
  "package": "my_package",
  "version": "1.2.0",
  "actor": "dev@example.com",
  "data": {"uploader": "dev@example.com", "sha256": "…"}
}
```

`version` is absent for package events. `id` names the event and stays the same when a delivery is sent again, so a receiver can drop duplicates. The headers are `Content-Type: application/json`, `User-Agent: unpub/<version>`, `X-Unpub-Event` (the event), `X-Unpub-Delivery` (the id of this delivery, new for every redelivery) and `X-Unpub-Signature: sha256=<hex>`, the HMAC-SHA256 of the exact body with the secret of the webhook.

**The secret** is 32 random bytes in base64url, made by the server and shown once, when the webhook is created or the secret is rotated. On the admin pages the post redirects to the page of the webhook, which shows the secret once from memory of that instance, for 5 minutes at most, so reloading neither creates nor rotates again. Behind a load balancer without sticky sessions that page can land on another instance and say the secret can no longer be shown: rotate it again then. Rotating there needs a checkbox ticked, and deleting goes through a confirmation page. It is stored as it is in MongoDB, because signing needs it, so treat the `webhooks` collection and its backups as secret. It never appears in logs, the audit log, listings or deliveries.

**Verifying** a delivery, in Dart, comparing in constant time:

```dart
import 'dart:convert';
import 'package:crypto/crypto.dart';

bool verify(String secret, List<int> body, String? header) {
  final expected = 'sha256=${Hmac(sha256, utf8.encode(secret)).convert(body)}';
  if (header == null || header.length != expected.length) return false;
  var difference = 0;
  for (var i = 0; i < expected.length; i++) {
    difference |= expected.codeUnitAt(i) ^ header.codeUnitAt(i);
  }
  return difference == 0;
}
```

or in a shell, with the body saved to `body.json`:

```sh
printf 'sha256=%s\n' "$(openssl dgst -sha256 -hmac "$SECRET" -hex < body.json | sed 's/^.* //')"
```

**Retries.** A 2xx answer is a success. Anything else, including a redirect, which is never followed, a timeout after `webhooks.timeout`, which covers resolving the host, connecting, sending and reading the answer together, or a connection error, is tried again after about 30 seconds, 2 minutes, 10 minutes and then every hour, each with 10 % jitter, until `webhooks.maxAttempts` attempts (5 by default) have failed and the delivery is marked `failed`. The status code, the first 1 KiB of the answer and the error of the last attempt are kept with the delivery. The admin page of a webhook lists its recent deliveries and sends a finished one again with **Redeliver**. Deliveries live in the `webhook_deliveries` collection. Instances sharing a database share the queue: each claims one due delivery at a time with an atomic `findAndModify`, a claim id of its own and a lease longer than an attempt, on the clock of the database, renewed every third of the lease while the attempt runs. The outcome is recorded only under that claim id, so a worker that stalled past its lease cannot overwrite the attempt that took over, and no attempt is sent twice. A worker in each instance looks for due deliveries every 5 seconds and right after an event. `webhooks.retentionDays` (30 by default, `0` keeps them) removes finished deliveries through a TTL index.

**Allowed targets.** Only `https` URLs are accepted, plain `http` too with `webhooks.allowHttp: true`, and URLs with credentials or a fragment are refused. Unless `webhooks.allowPrivateNetworks: true`, the host is resolved when each delivery is sent, every address it resolves to must be public, and the connection goes to the address that was checked, with TLS still verifying the host name. Refused are loopback, unspecified, link-local (including `169.254.169.254`), private (RFC 1918), shared (`100.64.0.0/10`), unique local (`fc00::/7`), site-local, multicast, broadcast and reserved addresses, also when written as IPv4-mapped or NAT64 IPv6 addresses. A refused address fails the delivery at once, without retries. Proxies from the environment are not used.

| Endpoint | Description |
| --- | --- |
| `GET /webapi/webhooks` | List webhooks, without secrets, as a page with `enabled`, the value of `webhooks.enabled`. |
| `POST /webapi/webhooks` | `{url, events, description?}`. Returns 201 with the `webhook` and its `secret`. |
| `GET /webapi/webhooks/<id>` | The webhook and its delivery counts by status. |
| `PATCH /webapi/webhooks/<id>` | Change `url`, `events`, `description` or `enabled`. |
| `POST /webapi/webhooks/<id>/secret` | Replace the secret, and return the new one. |
| `DELETE /webapi/webhooks/<id>` | Delete the webhook and its deliveries. |
| `GET /webapi/webhooks/<id>/deliveries` | The deliveries, newest first, paged. |
| `POST /webapi/webhooks/<id>/deliveries/<delivery>/redeliver` | Queue a delivery again, as a new delivery with the same body. |

They are for administrators, reading with the `read` scope and changing with the `publish` scope, from a token or a session with its CSRF token.

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
| `auth.readAccess` | `UNPUB_AUTH_READ_ACCESS` | `public` | `public`, or `authenticated` to require a token or session on every route except `/healthz`, `/readyz`, login and `/metrics`, which has its own rule. |
| `auth.bootstrapToken` | `UNPUB_AUTH_BOOTSTRAP_TOKEN` | | Deprecated. Static Bearer token that acts as an administrator. |
| `auth.bootstrapEmail` | `UNPUB_AUTH_BOOTSTRAP_EMAIL` | `admin@localhost` | Email of the `auth.bootstrapToken` identity, and the uploader recorded for its publishes. |
| `auth.readTokens` | `UNPUB_AUTH_READ_TOKENS` | | Deprecated. Static Bearer tokens that act as readers. A YAML list, or comma separated in the environment. |
| `audit.retentionDays` | `UNPUB_AUDIT_RETENTION_DAYS` | `0` | Days events are kept, through a TTL index. `0` keeps them for good. |
| `webhooks.enabled` | `UNPUB_WEBHOOKS_ENABLED` | `true` | Queue and deliver webhook events. |
| `webhooks.timeout` | `UNPUB_WEBHOOKS_TIMEOUT` | `10s` | How long one attempt may take, at most `5m`. |
| `webhooks.maxAttempts` | `UNPUB_WEBHOOKS_MAX_ATTEMPTS` | `5` | Attempts before a delivery is given up, 1 to 20. |
| `webhooks.allowHttp` | `UNPUB_WEBHOOKS_ALLOW_HTTP` | `false` | Accept plain `http` webhook URLs. |
| `webhooks.allowPrivateNetworks` | `UNPUB_WEBHOOKS_ALLOW_PRIVATE_NETWORKS` | `false` | Let webhooks reach loopback, link-local, private and unique local addresses. |
| `webhooks.retentionDays` | `UNPUB_WEBHOOKS_RETENTION_DAYS` | `30` | Days finished deliveries are kept. `0` keeps them. |
| `metrics.enabled` | `UNPUB_METRICS_ENABLED` | `true` | Serve `/metrics`. |
| `metrics.token` | `UNPUB_METRICS_TOKEN` | | Bearer token for scrapers. When set, `/metrics` needs it or an administrator, also in `public` mode. |
| `ui.assetsDir` | `UNPUB_UI_ASSETS_DIR` | `/app/ui`, else `ui/dist`, if they hold `index.html` | The built [web client](#web-client). When set it must hold `index.html`. |
| `ui.mode` | `UNPUB_UI_MODE` | `spa` with a client, `ssr` without | `spa`: the web client at `/` and the server-rendered pages under `/classic`. `ssr`: the pages at `/` and the client, if built, under `/app`. `spa` without a client is a startup error. |
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
- In `authenticated` mode the web UI sends visitors to its login page, see [Web UI](#web-ui). Badges under `/badge/...` need a token in that mode too, so public badge images stop working.
- A package without an `uploaders` list can now only be changed by an administrator.
- Accounts: run `unpub migrate` once. It creates a placeholder `publisher` for every email in existing `uploaders`, and an `admin` for `auth.bootstrapEmail` if it appears there. Check first with `unpub migrate --dry-run`. Placeholders cannot log in, so give them a password with `unpub admin set-password` or a token with `unpub admin create-token`.
- Run `unpub migrate` after creating your first administrator, or use `unpub admin create-user` afterwards: `auth.admin.*` is ignored once any user exists.
- `auth.bootstrapToken` and `auth.readTokens` keep working but are deprecated. Replace them with personal tokens. Neither these nor personal tokens can manage users over HTTP, so use `unpub admin` or log in.
- Package names must now match `[a-z_][a-z0-9_]*` and be at most 64 characters long. A stored package with any other name is no longer reachable.
- Archive hashes: `unpub migrate` step `0002_version_sha256` records the SHA-256 of every stored archive, so that existing versions get `archive_sha256`. Check first with `unpub migrate --dry-run`. An archive missing from storage is skipped with a warning, and that version keeps being served without a hash. Once the archive is back, `unpub migrate --rerun 0002` hashes the versions still missing one. Run it with the same `storage` settings as the server.
- The `latest` field of a listing now skips retracted versions, and the `/webapi` views use the same rule. Listings have new fields, and existing clients ignore what they do not know.
- MongoDB documents and the archive layout are unchanged apart from new optional fields. Archives stay in `unpub-packages` by default. Accounts live in the new collections `users`, `tokens`, `sessions`, `audit`, `admin_set` and `migrations`. Phase 3 adds `version_stats`, `upstream_cache`, `upstream_archives` and `upload_reservations`, and phase 5 `webhooks` and `webhook_deliveries`.

### Behind a reverse proxy

Set `server.publicUrl` to the external origin, and use HTTP/1.1 towards unpub:

```nginx
proxy_http_version 1.1;
proxy_set_header Host $host;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
client_max_body_size 100m;
```

Also set `server.trustForwardedFor: true`, or the login limit and the audit log see only the address of the proxy, and one user's failures would lock out everyone.

The web UI sends its own `Content-Security-Policy` and other security headers, see [Web UI](#web-ui). Pass them through unchanged: a proxy that adds a stricter policy, or injects scripts or styles into pages, breaks the UI, and one that adds `'unsafe-inline'` weakens it for nothing. Serve over HTTPS with `server.publicUrl` set to the `https://` origin, so that the session cookie is marked `Secure`.

## Operations

| Endpoint | Description |
| --- | --- |
| `GET /healthz` | Returns 200 while the process is up. |
| `GET /readyz` | Checks MongoDB and that storage accepts writes, by writing and deleting a probe (on S3, under `.unpub/`). Returns 200, or 503 with JSON details. |

The server logs one line per request to stdout, in text or JSON. On SIGINT or SIGTERM it stops accepting connections, drains requests for up to 30 seconds and closes MongoDB. A second signal exits immediately.

`GET /metrics` serves Prometheus metrics, see [Metrics](#metrics).

The server does not reconnect after losing its MongoDB connection. `/readyz` then keeps returning 503 until the process is restarted, so restart it when that happens.

### Metrics

`/metrics` answers in the Prometheus text format 0.0.4. Counters are kept per process and start at zero with it.

| Metric | Type | Description |
| --- | --- | --- |
| `unpub_http_requests_total{route,method,status}` | counter | Requests answered. `route` is the pattern of the route, such as `/api/packages/<name>`, never the path, the prefix of a mounted handler, or `unmatched`. `method` is `GET`, `HEAD`, `POST`, `PUT`, `PATCH`, `DELETE`, `OPTIONS` or `OTHER`, and `status` the status code, or `other` outside 100 to 599, so the number of series stays bounded. |
| `unpub_http_request_duration_seconds{route}` | histogram | Time to answer, with buckets at 5 ms, 25 ms, 100 ms, 500 ms, 2.5 s and 10 s. |
| `unpub_downloads_total` | counter | Archive downloads counted, as for the download statistics. Not labelled by package, to keep the series bounded. |
| `unpub_publishes_total` | counter | Versions published. |
| `unpub_upstream_fetches_total{result}` | counter | Requests to the upstream in proxy mode: `ok`, `not_modified`, `not_found` or `error`. |
| `unpub_webhook_deliveries_total{result}` | counter | Webhook attempts: `success`, `retry`, `failed` (given up) or `refused` (address or URL not allowed). |
| `unpub_packages`, `unpub_versions` | gauge | Packages and versions in MongoDB, read at most every 30 seconds. Left out for a custom `MetaStore` that does not override `counts`. |
| `unpub_storage_bytes` | gauge | Bytes in the package store, temporary files left out, measured by listing it in the background when the server starts and then at most every 10 minutes. A scrape never waits for the listing: it gets the last measurement, and no gauge until the first one completes. |
| `unpub_storage_measured_timestamp_seconds` | gauge | When `unpub_storage_bytes` was measured. |
| `unpub_mongo_up` | gauge | 1 if MongoDB answered a ping during the scrape. |
| `unpub_build_info{version}` | gauge | Always 1. |
| `process_start_time_seconds` | gauge | When the process started. |

With `auth.readAccess: public` and no `metrics.token`, anyone can read `/metrics`. Setting `metrics.token` makes it the Bearer token a scraper sends, and then, as always in `authenticated` mode, only that token or the token or session of an administrator with the `read` scope opens it. The metrics token opens nothing else. `metrics.enabled: false` turns the endpoint into a 404.

```yaml
scrape_configs:
  - job_name: unpub
    scheme: https
    metrics_path: /metrics
    authorization:
      type: Bearer
      credentials_file: /etc/prometheus/unpub-metrics-token
    static_configs:
      - targets: ['pub.example.com']
```

## Backup

Back up MongoDB and the package store together, MongoDB first: an archive without its version is only an orphan that reclamation removes, while a version without its archive answers 404.

| Collection | Back up | Why |
| --- | --- | --- |
| `packages` | yes | Versions, pubspecs, READMEs, uploaders, flags. Not derivable. |
| `users`, `tokens` | yes | Accounts and token hashes. Not derivable. |
| `audit` | yes, if you need the trail | Not derivable. |
| `webhooks` | yes | Webhooks with their secrets: protect the dump. |
| `stats`, `version_stats` | yes | Download counts, per package and day and per version. Not derivable. |
| `migrations` | yes | Which `unpub migrate` steps ran. |
| `admin_set` | optional | Rebuilt from `users` at every start. |
| `webhook_deliveries` | optional | The delivery log and queue. Without it, queued deliveries are lost. |
| `upstream_cache`, `upstream_archives` | no | Proxy mode only. Can be dropped: metadata and archives are fetched again. Drop both together with the `upstream/` part of the store. |
| `sessions`, `upload_reservations`, `object_locks` | no | Short lived. Users log in again. |

```sh
for c in packages users tokens audit webhooks stats version_stats migrations; do
  mongodump --uri "$UNPUB_MONGO_URI" --collection "$c" --out backup/
done
# File storage: copy the directory, leaving out .unpub-tmp/ and, if you want, upstream/.
rsync -a --exclude .unpub-tmp/ unpub-packages/ backup/unpub-packages/
# S3: copy the bucket, for example with versioning or replication, or
aws s3 sync s3://my-packages backup/s3/ --exclude '.unpub-tmp/*' --exclude '.unpub/*'
```

To restore, stop every instance, restore the package store, then `mongorestore` the collections, then start the server, which recreates the indexes and the admin set. Run `unpub migrate --dry-run` to confirm nothing is pending. Archives the restored database no longer names are removed by reclamation an hour after start; restore the store before the database so that it never finds a version without its archive.

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

`PublishPolicy` applies the `publish` settings, `UpstreamProxy` turns on proxy mode, and `WebhookService` (with a `WebhookStore` and its `start()` and `stop()`) adds webhooks. `App.metrics` holds the counters of `/metrics`. `MetaStore`, `PackageStore`, `Authenticator` and `AuditStore` can each be replaced by your own implementation. The account endpoints, and the login, account and admin pages of the web UI, are added by passing an `AccountApi`. The web UI is always part of `App.handler`; pass `config` to fill the admin settings page, and `ui` (a `UiConfig`) to serve a built web client and choose which UI is at `/`. `S3Store` and `FileStore` are included.

`ensureIndexes` creates the unique indexes that concurrent publishes rely on, and throws if `packages` already holds a name twice. To get reclamation as `unpub serve` does it, start a `TemporaryReclaimer` with `MongoArchiveReferences` too, which shares the `object_locks` of `MongoStore`.

## Web client

The web client is a single-page application in `ui/` (React, TypeScript, Vite), built into static files that this server serves; there is no second service and no CORS. It talks only to the [HTTP API](#http-api) with the session cookie and the `X-CSRF-Token` header, and has a page for everything the server-rendered UI does. The server-rendered pages stay, as the version without JavaScript and the fallback.

**Which UI is where.** With `ui.mode: spa`, the default when a built client is found, the client is at `/` and the server-rendered pages are under `/classic` (`/classic/packages/<name>`, `/classic/login`, `/classic/admin/...`): their links, forms, redirects and login cookie carry the prefix. `/static/` stays at the root as well. With `ui.mode: ssr`, the default without a client, the server-rendered pages are at `/` and the client, if built, under `/app`. The client routes mirror the server-rendered URLs, so `/packages/<name>` and `/classic/packages/<name>` show the same package.

**Serving.** Files under `assets/`, which Vite names by a hash of their content, are sent with `Cache-Control: public, max-age=31536000, immutable` and an `ETag`, other files of the build (favicon, manifest) for an hour, and `index.html` with `no-store`. Every GET or HEAD that accepts `text/html` and is not a path of the server (`/api`, `/webapi`, archives, `/badge`, `/static`, `/healthz`, `/readyz`, `/metrics`, `/classic`) gets `index.html`, so the client can route it. A missing file under `assets/` is a 404, and so is anything that does not accept HTML. Paths are resolved inside `ui.assetsDir`, dot segments, encoded slashes and hidden files are refused, and links out of it are not followed.

**Base path.** The server adds `<meta name="unpub-base" content="">` (or `/app`) and `<meta name="unpub-classic" content="/classic">` (or empty) to `index.html`, and rewrites its `./` references, and root-relative ones to files of the build, under the base path. Build the client with Vite's `base: './'` and read the base from the meta tag for the router, and one build works at `/` and under `/app`. `<base href>` cannot be used: the policy below forbids it.

**Security.** `index.html` is sent with the page policy plus `font-src 'self'`, so fonts and icons are bundled and nothing is inline:

```
Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' https: data:; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'; font-src 'self'
```

With `auth.readAccess: authenticated`, `index.html`, the files of the build, `GET /webapi/config` and `GET /webapi/openapi.yaml` stay open, so the client can show its own login, while the API answers 401. The server-rendered pages keep redirecting to their own login.

**Building.** The Docker image builds the client in a `node:22-alpine` stage (`npm ci`, `npm run build` in `ui/`) when `ui/package.json` exists, and copies `ui/dist` to `/app/ui`. From source, build it in `ui/` and run the server from the repository root so that `ui/dist` is found, or set `ui.assetsDir`. Without a build the server logs a warning and serves the server-rendered pages only.

## Web UI

The server renders every page itself. With `ui.mode: spa` these pages live under `/classic`, see [Web client](#web-client); the paths below are those of `ui.mode: ssr`. There is no frontend build and no third-party script, font or stylesheet: one stylesheet and one small script are served from `/static/`, and everything works without JavaScript.

| Page | Description |
| --- | --- |
| `/`, `/packages` | The package list. `q` searches names and descriptions, `sdk=dart` or `sdk=flutter` filters, `discontinued=1` includes discontinued packages, `sort` is `relevance` (the default with `q`), `downloads` (the default otherwise), `updated` or `name`, and `page` and `size` (20 by default, at most 100) page through it. With JavaScript, the list updates while typing. |
| `/packages/<name>` | The latest version, with the tabs `?tab=readme`, `changelog`, `versions`, `install` and the statistics, and a sidebar with the SDK constraints, platforms, links, dependencies, uploaders and, for a package from the upstream, a link to it. |
| `/packages/<name>/versions/<version>` | The same for one version. |
| `/packages/<name>/stats` | Download statistics: the total, the last 30 days as a table and a bar chart, and the most downloaded versions. |
| `/login`, `/account` | Log in and out, change the password, and list, create and revoke personal tokens. |
| `/admin/users`, `/admin/packages`, `/admin/webhooks`, `/admin/audit`, `/admin/settings` | Administrators only, see below. |

Search finds the packages that have every word of the query, ignoring case, anywhere in the name or in a description, so `parser documents` does not find a package that only mentions one of them. The results are ordered by relevance with a MongoDB text index on names and descriptions, created by the server at startup with stemming for English, and packages it does not match, such as one found by part of a word, come after. Without the index, for example when another text index already exists on `packages`, the same packages are found, ordered by downloads, and a warning is logged at startup. A package counts as a Flutter package when any of its versions has a `flutter` section, an `environment.flutter` constraint or a dependency on `flutter`. An unknown package name sends the browser to the upstream in proxy mode, and shows a 404 page with a link to the upstream otherwise.

README and CHANGELOG are rendered as GitHub flavoured markdown and then sanitized through an allowlist of elements and attributes. Scripts, styles, frames, forms, event handlers and `javascript:` or `data:` URLs are removed. Links to other sites get `rel="nofollow noopener"` and open in a new tab. Only the first 512 KiB of a file is rendered, with a notice.

The files of a package are not served, so URLs relative to the document are rewritten or removed:

- Links to `http`, `https` and `mailto` URLs are kept. A link to a fragment, `#usage`, is kept and leads to the heading of that name: headings get an id prefixed with `md-`, such as `md-usage`, and fragments are prefixed alike.
- A link to a relative path, `doc/usage.md`, `/LICENSE` or `../other`, leads into the repository: `<repository>/blob/HEAD/<path>`, with `repository` from the pubspec, or `homepage` if it is on `github.com` or `gitlab.com`, when it is an `https` URL. A repository URL naming a directory, like `https://github.com/org/repo/tree/main/packages/a`, is browsed from that directory and branch. Without such a URL the link is removed and its text stays.
- Images must be `http` or `https` URLs. A relative image is replaced by its alt text.

**Logging in.** Users log in with their email and password on `/login`. Failures show one generic message and count towards the same rate limit as `POST /webapi/login`. After logging in the browser goes back to the page it came from, which must be a path on this server. The login form carries its own token in a `SameSite=Strict` cookie, as there is no session yet.

**Tokens.** `/account` lists the tokens of the user with their prefix, scopes, creation, last use and expiry, creates one with a name, scopes and a lifetime, and revokes them. A new token's secret is shown once, with the `dart pub token add` command to use it, on the page the form redirects to, so reloading does not create another token. A reader can only create `read` tokens.

**Administration.** `/admin/users` lists the users and creates, promotes, demotes, disables, enables them and sets their passwords. `/admin/packages/<name>` discontinues a package, optionally with its replacement, retracts and restores versions, and adds and removes uploaders. It also deletes versions and the package and transfers the ownership, see [Package management](#package-management). These apply the same rules as the API and are audited in the same way. `/admin/webhooks` manages webhooks and shows their deliveries, see [Webhooks](#webhooks), and `/admin/audit` the audit log, see [Audit log](#audit-log). `/admin/settings` shows the effective configuration, with the MongoDB credentials, S3 keys, `auth.bootstrapToken`, `auth.readTokens`, `metrics.token` and the administrator password replaced by `<redacted>`. `/admin/packages` pages through every package with `q`, `page` and `size` (100 by default). Only administrators logged in with a password open these pages: an API token or a static token gets a 403 page whatever its scopes, and so does everyone else.

**Security.** Every form that changes something carries the CSRF token of the session, and a missing or wrong one answers a 403 page. Changing credentials, roles or packages from the UI needs a password login, as on the JSON API. The session cookie is `HttpOnly` and `SameSite=Lax`, and `Secure` when `server.publicUrl` is `https`. Pages are sent with:

```
Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' https: data:; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'
X-Content-Type-Options: nosniff
Referrer-Policy: strict-origin-when-cross-origin
X-Frame-Options: DENY
```

`connect-src 'self'` lets the script fetch the list while typing. Pages are `Cache-Control: no-store` once logged in and `private, max-age=0` otherwise. The stylesheet and script are cached for a year, with an `ETag`, and linked with a hash of their content.

**`auth.readAccess: authenticated`.** A browser asking for any page without a session is sent to `/login`, and back afterwards. The login page, `/static/` and the health probes stay open. API clients, and any request that does not accept `text/html`, still get the 401 challenge. Badges need a token in this mode.

**Download statistics.** `/packages/<name>/stats` reads the daily counters that every counted download increments in the `stats` collection, `d<yyyyMMdd>` fields of the document of the package, by day in the local time of the server. Existing counts back to the first 3.x release show up. The chart is SVG drawn by the server, with classes for the stylesheet and no `style` attribute or script, so the Content-Security-Policy stays as it is. The page is public in `public` mode and needs a session in `authenticated` mode, like the other pages.

**Errors.** A browser gets small HTML pages for 403, 404 and 500. Every API path (`/api/`, `/webapi/`, archives, `.json`, badges, the probes) answers JSON or plain text as before.

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

Set `UNPUB_TEST_MONGO_URI` to use another database. The S3 tests run when `UNPUB_TEST_S3_ENDPOINT` points to an S3 compatible service. Run `make generate` after changing the JSON models. Commits follow [Conventional Commits](https://www.conventionalcommits.org).

`docs/openapi.yaml` is served from a copy in `lib/src/routes/openapi_document.dart`: run `dart run tool/embed_openapi.dart` in `unpub/` after changing it, a test checks both and that every documented route exists and every `/webapi` route is documented. CI lints it with `npx @redocly/cli lint docs/openapi.yaml`, configured by `redocly.yaml`.

The server-rendered web UI needs no build step. Routes are registered by hand in `lib/src/routes/` and `lib/src/web/web_ui.dart`. Pages are plain Dart functions in `lib/src/web/pages/` built with the `el` helper of `lib/src/web/html.dart`, which escapes all text and attribute values; unescaped markup only goes through `Html.trusted`, used for the sanitized markdown. The stylesheet and script are string constants in `lib/src/web/assets.dart`.

## Credits

- [pub-dev](https://github.com/dart-lang/pub-dev): the API this server implements.
- [shields](https://shields.io): badge generation.
- [bytedance/unpub](https://github.com/bytedance/unpub): the project this is forked from.

## License

MIT
