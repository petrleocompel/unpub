# unpub roadmap: full self-hosted Dart/Flutter package registry

This document is the shared specification for the modernization of unpub.
Every implementation phase is a separate pull request into `master`.
Decisions below were made by the project owner on 2026-11-09 and are not open for re-negotiation inside a phase.

## Decisions

| Topic | Decision |
|---|---|
| Architecture | Single Dart monolith: one `unpub` package, one binary, one Docker image. |
| Dart SDK | Dart 3 (target the SDK installed locally: 3.12, constraint `^3.5.0`). Null safety everywhere. |
| Metadata store | MongoDB stays (`mongo_dart`, upgraded). Existing collections `packages` and `stats` must keep working. New fields are additive; a `unpub migrate` command handles non-additive changes. |
| Package (tarball) store | File system and S3 both in core, selected by config. `unpub_aws` is folded into `unpub` and removed as a package. |
| Web UI | Server-side rendered HTML from shelf. Minimal JavaScript. `unpub_web` (AngularDart) is deleted. |
| Auth | Local user accounts with password, roles `admin` / `publisher` / `reader`, personal API tokens for `dart pub token add`. Google OAuth flow and `unpub_auth` are removed. |
| Upstream (pub.dev) | Redirect by default. Optional caching proxy mode configurable. |
| Configuration | YAML config file plus environment variable overrides. CLI flags only for `--config`, `--host`, `--port`. |
| Dartdoc | Not generated. README and CHANGELOG are rendered from markdown. |
| Existing data | A running instance with data in Mongo exists. Preserve it. Legacy uploader emails map to users. |

## Repository conventions

- Conventional commits (`feat:`, `fix:`, `refactor:`, `docs:`, `chore:`, `test:`).
- `dart format` clean, `dart analyze` clean with `package:lints/recommended.yaml`.
- Tests run against a real MongoDB. CI (GitHub Actions) provides it as a service container. Locally use `docker compose -f docker-compose.dev.yml up mongo`.
- Keep the public pub API URL shape unchanged. Clients: `dart pub` 3.x, `flutter pub`.
- No breaking changes to the Mongo documents unless covered by `unpub migrate`.
- Every phase updates `README.md` and `CHANGELOG.md`.

## Phase 1: foundation (Dart 3, config, Docker)

Goal: the server builds and runs on Dart 3 with the same external behaviour as today, is configurable from a file and ships as a Docker image.

- Upgrade `unpub/pubspec.yaml` to Dart 3, upgrade all dependencies (`mongo_dart`, `http`, `shelf`, `shelf_router`, `archive`, `googleapis` removed, `json_serializable`, etc.). Regenerate `*.g.dart`.
- Delete `unpub_web`, `unpub_auth`. Move S3 store from `unpub_aws` into `unpub/lib/src/store/s3_store.dart` and delete `unpub_aws`. Keep `FileStore`.
- Keep serving the already compiled static UI (`lib/src/static/*.dart`) unchanged until phase 4 replaces it.
- `Config` class loaded from YAML (`unpub.yaml`) with env overrides `UNPUB_*`. Sections: `server` (host, port, publicUrl), `mongo` (uri), `storage` (type file|s3, options), `upstream` (url), `auth` (placeholder for phase 2), `logging` (level, json). Validate at startup with clear errors.
- `bin/unpub.dart`: `unpub serve --config unpub.yaml`, `unpub --help`, `unpub version`. Reserve subcommands `migrate`, `admin` for later phases.
- Endpoints `/healthz` (process up) and `/readyz` (Mongo reachable, storage writable).
- Structured logging via `package:logging` with text or JSON output. Replace `print` calls. Graceful shutdown on SIGTERM/SIGINT.
- Remove the env-variable auth hacks (`UPLOAD_TOKEN`, `UPLOAD_EMAIL`, `ALLOWED_TOKENS`) and Google tokeninfo. Until phase 2, publishing is gated by a single config value `auth.bootstrapToken` (Bearer) so the server stays usable.
- `Dockerfile` (multi-stage, `dart compile exe`, scratch or distroless runtime), `docker-compose.yml` (unpub + mongo), `docker-compose.dev.yml` (mongo only).
- GitHub Actions: analyze, format check, tests with Mongo service container, Docker build.
- Tests green on Dart 3.

## Phase 2: users, roles, API tokens, protected reads

Goal: real authentication and authorization.

- Collections `users` (email, displayName, passwordHash argon2id or bcrypt, role, createdAt, disabled), `tokens` (userId, name, hashed secret, prefix, scopes, expiresAt, lastUsedAt, createdAt), `sessions` or signed cookies for the web UI.
- Roles: `admin` (everything), `publisher` (publish, manage own packages' uploaders), `reader` (read only).
- Package uploaders remain a list of user emails for compatibility. Authorization checks resolve the authenticated user's email against it.
- Admin bootstrap: `auth.admin.email` + `auth.admin.password` in config or env creates the first admin at startup if no users exist. CLI `unpub admin create-user`, `unpub admin set-password`.
- Tokens: created in the web UI (phase 4) and via `POST /webapi/tokens`. Shown once. Stored hashed. Used as `Authorization: Bearer <token>` by `dart pub`. Document `dart pub token add <url>` flow in README.
- Read protection: config `auth.readAccess: public | authenticated`. In `authenticated` mode every pub API, tarball download and web page requires a token or session. Pub client sends the token for `pub get` when added via `dart pub token add`.
- `unpub migrate` step: create placeholder users (role `publisher`, no password, must be set by admin) for every email found in existing `uploaders` arrays.
- Audit hook interface (`AuditStore.record(event)`) with Mongo implementation `audit` collection. Record login, token create/revoke, publish. Phase 5 adds UI and more events.
- Tests for every authorization path.

## Phase 3: pub API completeness, policies, upstream cache

Goal: behave like pub.dev for modern clients and enforce publishing rules.

- Version listing: `archive_sha256` (computed on upload, stored; `unpub migrate` backfills from stored tarballs), `published` timestamp, `latest` excludes prereleases unless only prereleases exist, `retracted` flag.
- Package flags `isDiscontinued`, `replacedBy`; version flag `isRetracted`, `retractedAt`. Endpoints: `PUT /api/packages/<name>/discontinue`, `POST /api/packages/<name>/versions/<version>/retract` and `unretract` (admin or uploader). Retracted versions are hidden from `latest` and marked in listings. If every version of a package is retracted, `latest` is the highest version anyway, as on pub.dev, so that the listing stays valid.
- `GET /api/packages/<name>/advisories` returns an empty, valid response.
- Proper HTTP caching: `ETag` and `Cache-Control` on listing and tarball responses, `304` support.
- Upload policies from config `publish`: `allowedNamePrefixes`, `maxArchiveBytes`, `requiredFiles` (e.g. README.md, CHANGELOG.md, LICENSE), `rejectOlderThanLatest`, `requireVersionBump`. Keep the Dart `uploadValidator` callback for programmatic use.
- Upstream `upstream.mode: redirect | proxy`. In proxy mode fetch metadata and tarballs from `upstream.url`, store them in the package store under a separate namespace, serve from cache with `upstream.cacheTtl`. Proxied packages are marked `private: false` and cannot be published to.
- Per-version download counts in addition to per-package.
- Tests with the real `dart pub` client for publish, get, retract, discontinued.

## Phase 4: server-side rendered web UI

Goal: replace the AngularDart bundle with HTML rendered by the server.

- Delete `lib/src/static/*`. Templates in `lib/src/web/templates` using a maintained Dart templating approach (plain Dart functions with HTML escaping or `mustache_template`). Shared layout, CSS in a single static file, optional htmx for search-as-you-type. No frontend build step.
- Pages: home, package list with full-text search (name + description, Mongo text index), filters (Flutter/Dart, discontinued hidden by default), sorting (downloads, updated, name), pagination.
- Package detail: README and CHANGELOG rendered with `package:markdown` and sanitized, install snippet (`dart pub add <name> --hosted-url ...`), pubspec snippet with copy button, versions tab with date, uploader and retracted badge, dependencies with links, SDK constraints, platform tags, uploaders, pub.dev link for proxied packages.
- Account: login/logout, change password, token list with create (shown once) and revoke, expiry.
- Admin panel: users (create, role, disable, reset password), packages (discontinue, retract, uploaders), settings overview (read only).
- Security: CSRF tokens on forms, `Content-Security-Policy`, `HttpOnly`/`SameSite` cookies, rate limit on login.
- Badges endpoints stay.

## Phase 5: administration, audit, webhooks, metrics

Goal: operate the registry in production.

- Package management API and UI: delete version, delete package, add/remove uploader, transfer ownership. All require admin or uploader as specified; all audited.
- Audit log: events for publish, delete, retract, discontinue, uploader changes, user and token changes, logins. `GET /webapi/audit` with filters and an admin UI page.
- Webhooks: config and admin UI, events `package.published`, `version.retracted`, `package.discontinued`, HMAC SHA-256 signature header, retries with backoff, delivery log.
- Prometheus `/metrics`: requests, downloads, publishes, storage size, Mongo health.
- Download statistics page per package (daily counts from `stats`).
- Backup notes in README (Mongo dump + storage directory or S3 bucket).

## Out of scope

- dartdoc generation.
- OIDC / external identity providers.
- Multiple registries or scopes in one instance.
- PostgreSQL or SQLite backends.
