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

Decisions added on 2026-11-10 for the single-page client (phase 6):

| Topic | Decision |
|---|---|
| Client | A single-page application in `ui/` in this repository, React 19 + TypeScript + Vite, Tailwind CSS with shadcn/ui (Radix) components, TanStack Query, React Router. Built with Node 22 and `npm ci`, `package-lock.json` committed. No server-side rendering of the SPA. |
| Deployment | One Docker image: a Node build stage produces `ui/dist`, copied into the runtime image at `/app/ui`. The Dart server serves it (`ui.assetsDir`) with a SPA fallback. No second service, no CORS. |
| Two UIs | The server-rendered UI from phase 4 stays, permanently, as the no-JavaScript and fallback UI. `ui.mode: spa` (default when assets exist) serves the SPA on `/` and the server-rendered pages under `/classic/...`; `ui.mode: ssr` swaps them, the SPA then lives under `/app/...`. Every feature exists in both. |
| API contract | The SPA talks only to `/webapi/*` and the management routes under `/api/*`, with the session cookie and the `X-CSRF-Token` header. The contract is `docs/openapi.yaml`, hand-written, and the client types are generated from it. |
| Security | The strict `Content-Security-Policy` of phase 4 applies to the SPA too: no inline scripts or styles, no third-party origins, fonts and icons bundled. |
| Design | The visual design comes from Claude Design, briefed by `docs/DESIGN_BRIEF.md`: public pages familiar to pub.dev users, account and administration as a dashboard. The first implementation uses the default shadcn/ui look and is restyled when the design lands. |

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

## Phase 6: single-page web client

Goal: a rich client for the same registry, next to the server-rendered pages, without a second service.

Part A, server (first pull request or first commits):

- `docs/openapi.yaml` describing every `/webapi/*` route and the management routes under `/api/*` that the client uses, with schemas, error shape `{error: {code, message}}`, and the cookie + `X-CSRF-Token` security scheme. Validate it in CI (`npx @redocly/cli lint` or a Dart check that every documented route exists).
- Fill the gaps the client needs, all under `/webapi`: `GET /webapi/config` (public: `version`, `publicUrl`, `readAccess`, `upstream.url` and `mode`, `features` such as whether metrics and webhooks are enabled); `GET /webapi/packages` with `q`, `sdk`, `discontinued`, `sort`, `page`, `size` and the same semantics as the page (`total`, `items`); `GET /webapi/package/<name>` and `/<name>/<version>` adding sanitized `readmeHtml` and `changelogHtml` rendered by the phase 4 markdown pipeline, plus dependencies, SDK constraints, platforms, uploaders, retraction and discontinued flags; `GET /webapi/package/<name>/stats` (daily counts, totals, per-version totals); `GET /webapi/settings` (administrators: the redacted effective configuration); `GET /webapi/audit` as is. Mutations the SPA performs go through the existing routes; every one of them must accept a session with `X-CSRF-Token` as well as a Bearer token, and answer JSON.
- Asset serving: `ui.assetsDir` (default `/app/ui` in the image, `ui/dist` otherwise, the SPA disabled with a warning when absent), hashed assets `public, max-age=31536000, immutable`, `index.html` `no-store`, SPA fallback for GET requests that accept HTML and are not API, archive, badge, static or classic routes. `ui.mode` as decided. The server-rendered router takes a base path so that it can live under `/classic`. `readAccess: authenticated` keeps the SPA shell and its assets reachable so the client can show its own login; the API answers 401 and the client redirects to login.
- CSP for the SPA shell identical to the phase 4 policy, plus `font-src 'self'`.
- Dockerfile with the Node build stage, CI job `ui` (`npm ci`, `npm run lint`, `npm run typecheck`, `npm test`, `npm run build`), docker job unchanged otherwise.

Part B, client in `ui/`:

- Pages with parity to phase 4: package list with search as you type, filters, sorting and pagination synced to the URL; package and version pages with README, CHANGELOG, versions, install snippets with copy, dependencies, stats with a chart; login; account with password change and tokens; admin dashboard with users, packages (moderation, delete, transfer), audit with filters, webhooks with deliveries and redeliver, settings. Every page has loading, empty and error states, and a `<noscript>` link to the classic page.
- Routing mirrors the server-rendered URLs (`/packages/<name>`, `/packages/<name>/versions/<version>`, `/login`, `/account`, `/admin/...`) so links are interchangeable between both UIs.
- Keyboard: `/` focuses search, dialogs trap focus, all actions reachable by keyboard. WCAG 2.1 AA contrast, visible focus, labels on inputs, tables with headers. Dark mode follows the system with a manual toggle.
- Tests: Vitest with Testing Library and MSW for the pages, a Playwright smoke run against the real server in CI (build, serve with Mongo, login, list, detail, token create, admin user create) in its own job.
- README section "Web client" and the `ui/README.md` for development (`npm run dev` proxies `/webapi` and `/api` to a local server).

## Out of scope

- dartdoc generation.
- OIDC / external identity providers.
- Multiple registries or scopes in one instance.
- PostgreSQL or SQLite backends.
