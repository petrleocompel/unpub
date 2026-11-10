## 3.0.0-dev.6

Prepares the server for the single-page web client of phase 6: the JSON API it needs, described in `docs/openapi.yaml`, serving its build next to the server-rendered pages, and building it into the image. See "Web client" and "HTTP API" in the README.

- Adds the `ui` config section: `ui.assetsDir`, the built client, by default `/app/ui` or `ui/dist` when they hold `index.html`, and `ui.mode`, `spa` (the client at `/`, the server-rendered pages under `/classic`) by default when a client exists, `ssr` (the pages at `/`, the client under `/app`) otherwise. `spa` without a client is a startup error, and the server logs a warning when it finds none.
- Serves the client: files under `assets/` with `Cache-Control: public, max-age=31536000, immutable` and an `ETag`, other files of the build for an hour, and `index.html` with `no-store` and the page `Content-Security-Policy` plus `font-src 'self'` for every GET or HEAD that accepts HTML and is not a path of the server (`/api`, `/webapi`, archives, `/badge`, `/static`, the probes, `/metrics`, `/classic`). The shell gets `<meta name="unpub-base">` and `<meta name="unpub-classic">` with the two base paths, and its `./` references and those to files of the build move under the base path, so one build with Vite's `base: './'` works at `/` and under `/app`. Nothing outside the build directory, and no hidden file, is served. With `auth.readAccess: authenticated` the shell and its files stay open so the client can show its own login.
- With `ui.mode: spa` the server-rendered pages, their forms, redirects and login cookie move under `/classic`. `/static/` stays at the root too.
- Adds `GET /webapi/config`, open in every read mode: version, public URL, read access, accounts, upstream URL and mode, features and the paths of both UIs.
- Adds `GET /webapi/v2/packages`, the search of the package list page with `q`, `sdk`, `discontinued`, `sort`, `page` and `size` (at most 100), answering `{items, page, size, total}` of package summaries.
- Adds `GET /webapi/package/<name>`, the latest version. It and `GET /webapi/package/<name>/<version>` add `readmeHtml` and `changelogHtml`, rendered and sanitized as on the package page, `latest`, `published`, `uploader`, `devDependencies`, `environment`, `platforms`, `retracted`, `archiveSha256`, `private`, `isFlutter`, `homepage`, `repository`, `issueTracker`, `documentation`, `license`, and `published`, `retracted` and `prerelease` on every version, listed highest first.
- Adds `GET /webapi/package/<name>/stats`: the total, the last 30 days zero-filled, and every version's downloads.
- Adds `GET /webapi/settings` and `GET /webapi/admin/overview` for administrators with the `read` scope: the redacted configuration with the environment variable of each key, and the counts, storage size, publishes and failed deliveries of the last day, recent publishes and readiness checks.
- `GET /webapi/users` searches with `q` and is paged. Every list route takes a one-based `page` and `size` and answers `{items, page, size, total}`.
- `POST /api/packages/<name>/uploaders` also takes `{"email": ...}` as JSON.
- Every JSON error has a `code` next to its `message`: `invalid_request`, `unauthorized`, `forbidden`, `not_found`, `conflict`, `bad_gateway` and the codes the account routes had.
- Package summaries of `GET /webapi/v2/packages` have `versionCount` and `uploaders`, so the admin package table needs one call. Only packages published here are listed, so `private` is always true.
- Every item of `GET /webapi/webhooks` has `deliveries: {pending, succeeded, failed}`, counted for the whole page in one aggregation.
- Deliveries in `GET /webapi/webhooks/<id>/deliveries` have `payload`, the exact body that `X-Unpub-Signature` signs, and `durationMs`, the time of the last attempt, now stored with each attempt (null for deliveries attempted before).
- `expiresIn` of a new token also takes years, such as `1y` (365 days), and `never`, the same as leaving it out. Durations in the configuration take `y` too.
- The spec has examples for the main objects, no longer requires the deprecated `createdAt` and `isRetracted` of a version (still sent), and documents that `User.displayName` is never null and the package detail stays wrapped in `data`.
- The shell is served by the `q` values of `Accept`: the most specific range matching `text/html` decides, so `text/html;q=0` gets no shell while `*/*` does. `index.html` is read only if it resolves inside the build, checked when the client is built and on every read; otherwise the request gets a 500 and the reason is logged.
- `page` is at most 100000 on every list route, so a huge one can no longer overflow the offset; a page past the end is an empty page. Digits too long for an integer count as out of range rather than as missing.
- `SpaClient` and `spaContentSecurityPolicy` are exported.
- Links of `index.html` to the server-rendered pages, `href="/classic/..."`, are moved to where the pages are, so the `<noscript>` link of the client leads to `/` with `ui.mode: ssr`.
- Every item of `versions` in `GET /webapi/package/<name>[/<version>]` has `archiveSha256`, null when the hash of that archive is not known.
- `GET /webapi/me` is open in every read mode and answers 200 with `{"user": null}` when nobody is logged in, instead of 401, so browsers log no failed request on every anonymous page. A session cookie that is not accepted any more, such as an expired one, is cleared. A token without the `read` scope still gets 403 with `auth.readAccess: authenticated`.
- Serves `docs/openapi.yaml` at `GET /webapi/openapi.yaml`. A test checks it against the router, and CI lints it and builds and tests the client once `ui/package.json` exists.
- The Docker image builds the client in a `node:22-alpine` stage when `ui/package.json` exists and copies it to `/app/ui`.
- Adds the web client in `ui/`: React 19, TypeScript, Vite, Tailwind CSS and shadcn/ui, with every page of the server-rendered UI at the same paths (package list and pages with statistics, login, account and tokens, and the administration of users, packages, the audit log, webhooks and settings), dark mode, page tests with Vitest and MSW, and a Playwright run against the server in CI (`ui-e2e`). The Docker image now contains it at `/app/ui`. See `ui/README.md`.
- **Breaking:** `GET /webapi/users`, `GET /webapi/tokens`, `GET /webapi/webhooks`, `GET /webapi/webhooks/<id>/deliveries` and `GET /webapi/audit` answer `{items, page, size, total}` instead of `{users}`, `{tokens}`, `{webhooks, enabled}` (`enabled` stays), `{deliveries}` and `{events, count, page, size}`.
- **Breaking:** in `GET /webapi/package/<name>/<version>`, `dependencies` is a list of `{name, constraint, hosted, local}` instead of names, `versions` is ordered highest first with prereleases in place, `homepage` is null rather than an empty string without one, and a missing package or version answers 404 with an error instead of 200 with `{"error": "..."}`.
- **Breaking:** `App` gains the argument `ui` (a `UiConfig`, the server-rendered pages only by default) and `spaClient`, and throws an `ArgumentError` for `UiMode.spa` without `assetsDir`. `WebUi` takes a `basePath`, the `classicBasePath` of `App.ui` by default. `WebUi.loginLocation` reads the path of the request relative to the base path. `authMiddleware` gains `pagesPath` and `isOpenRequest`, and `isOpenPageRequest` a `pagesPath`. `badRequest` and the helpers built on it take a `code`. `WebapiDetailView` loses `dependencies`. `Config` has a `ui` section, and `DownloadStats.load` a `top`.

## 3.0.0-dev.5

Adds what is needed to run the registry in production: package management, an audit log, webhooks, Prometheus metrics, download statistics and backup notes. See "Package management", "Audit log", "Webhooks", "Operations", "Backup" and "Web UI" in the README.

- The package store measurement behind `unpub_storage_bytes` recovers from a store that fails before its first await, and is stopped on shutdown.
- Adds `DELETE /api/packages/<name>/versions/<version>`, `DELETE /api/packages/<name>` and `PUT /api/packages/<name>/owner` (`{"email": ...}`), for administrators, and the same on `/admin/packages/<name>`: a confirmation page before deleting a version, a form that needs the package name typed before deleting the package, and a transfer form. The last version cannot be deleted (409). Archives go under the per-digest lock, and only once nothing else names their digest. A deletion reserves every version it deletes as a publish does, and deletes the package document only while it holds exactly those versions, so a racing publish never leaves a version without its package or an archive behind.
- Audit events have the same fields everywhere: `at`, `action`, `actor`, `actorKind`, `token`, `ip`, `package`, `version`, `target` and `details`. Adds `version.deleted`, `package.deleted`, `uploader.transferred`, `user.role_changed`, `user.disabled`, `user.enabled` and the `webhook.*` actions. Adds indexes on `package`, `actor` and `action` with `at`.
- Adds `GET /webapi/audit`, filtered by `action`, `actor` (or `token:<prefix>`), `package`, `from` and `to`, paged by `page` and `size` (at most 200), and the admin page `/admin/audit`.
- Adds `audit.retentionDays`, 0 by default, applied as a TTL index that every start creates, changes or drops.
- Adds webhooks in the new `webhooks` collection, managed on `/admin/webhooks` and `/webapi/webhooks`, for `package.published`, `version.retracted`, `version.unretracted`, `package.discontinued`, `package.continued`, `version.deleted` and `package.deleted`. Deliveries are signed with `X-Unpub-Signature: sha256=<HMAC-SHA256>`, queued in the new `webhook_deliveries` collection shared by every instance, and retried with backoff up to `webhooks.maxAttempts`. https only and no private addresses unless configured, checked after DNS resolution, no redirects followed. Adds the `webhooks` config section.
- Adds `GET /metrics` in the Prometheus text format, with request counts and durations by route pattern, downloads, publishes, upstream fetches, webhook deliveries, packages, versions, storage size, MongoDB health and the build. Adds the `metrics` config section, with `metrics.token` for scrapers.
- Adds `/packages/<name>/stats` and a Stats tab: the last 30 days of downloads as a table and an SVG chart drawn by the server, from the daily counters `stats` already holds, and the most downloaded versions.
- `/admin/settings` shows the new sections, with `metrics.token` redacted.
- Once a deletion has removed the version or the package document, removing download counts, stale reservations and archives is best effort: a failure is logged and recorded as `details.cleanupError` in the audit event, the webhook event is still queued and the client still gets success, instead of an error that a retry answers with 404.
- A webhook attempt has one deadline, `webhooks.timeout`, for resolving the host, connecting, sending and reading the answer, instead of a full timeout for each step. Each claim of a delivery has its own `claimId`, the lease is renewed while the attempt runs, and only the attempt holding the claim records its outcome, so a stalled worker can neither send an attempt twice nor overwrite a newer one.
- Creating a webhook, rotating its secret and creating a personal token on the web pages redirect (303) to a page that shows the secret once, kept in the memory of the instance for the session for 5 minutes. Reloading no longer creates or rotates again.
- Transferring ownership and deleting a webhook on the admin pages go through a confirmation page, and rotating a webhook secret needs a checkbox. Posts without the confirmation are refused with 400 and change nothing, so the pages no longer rely on JavaScript for it.
- The `method` label of `unpub_http_requests_total` is one of `GET`, `HEAD`, `POST`, `PUT`, `PATCH`, `DELETE`, `OPTIONS` or `OTHER`, and `status` is `other` outside 100 to 599. A handler mounted on the router is labeled with its prefix instead of `unmatched`.
- `unpub_storage_bytes` is measured in the background at startup and at most every 10 minutes, so a scrape never waits for listing the store. Adds `unpub_storage_measured_timestamp_seconds`.
- The audit page keeps a date window and a page size across its pages, and the download chart has a `<title>`, a `<desc>`, thousands separators and a mid tick.
- **Breaking:** `AuditEvent` takes `actorKind`, `token`, `package` and `version`, and `target` is optional. `AuditContext` takes `token`, and `AuditContext.of(principal)` builds one. `AuditStore` gains `query`, with an empty default. `MongoAuditStore.ensureIndexes` takes the retention and drops the TTL index without one.
- **Breaking:** `MetaStore` gains `removeVersion`, `deletePackage` and `setUploaders`, which throw `UnsupportedError` by default, `removeVersionData` and `removePackageData`, which remove the download counts and stale reservations after a deletion, and `archiveReferences`, `counts` and `dailyDownloads` with defaults. `counts` answers null by default, which leaves the package gauges out: a store that can count cheaply overrides it. `PackageStore` gains `deleteLegacy` and `totalSize`. `App` gains `webhooks` and `metrics`, and `App.router` is a `PatternRouter`.

## 3.0.0-dev.4

Replaces the AngularDart UI with HTML rendered by the server. See "Web UI" in the README.

- Adds the package list on `/` and `/packages`, with search over names and descriptions, filters for the SDK and discontinued packages, sorting by relevance, downloads, update time or name, and pagination. A search finds the packages having every one of its words, ignoring case, in the name or a description, with or without the new text index on `packages`, which only orders them by relevance. The index is created at startup and skipped with a warning if it cannot be. Relevance is offered in the sort while there is a query. Page numbers are bounded, so an out of range one is an empty page.
- A link or image whose `http` or `https` URL has no host, such as `https:evil`, or contains a backslash, is dropped, as browsers would resolve it against the page.
- Adds package and version pages with the README and CHANGELOG rendered from markdown and sanitized, their first 512 KiB, headings with ids prefixed `md-` that fragment links lead to, also for headings starting with a digit such as versions in a CHANGELOG, relative links leading into the `repository`, or a GitHub or GitLab `homepage`, as `<repository>/blob/HEAD/<path>` and reduced to their text otherwise, and relative images replaced by their alt text, the versions with date, uploader, retraction and hash, install snippets using `server.publicUrl`, SDK constraints, platforms, dependencies linked to local packages or the upstream, uploaders and the discontinued notice.
- Adds `/login`, logout and `/account`: change the password, list, create (shown once) and revoke personal tokens. Login shares the rate limit of `POST /webapi/login`.
- Adds the admin pages `/admin/users` (create, role, disable, enable, set password), `/admin/packages/<name>` (discontinue with a replacement, retract and restore versions, add and remove uploaders, audited like the API) and `/admin/settings` (the effective configuration with secrets redacted). They need a password login: every API or static token gets a 403 page, whatever its scopes. `/admin/packages` pages through every package.
- Every form is protected by the CSRF token of the session, the login form by a token of its own. Pages send a `Content-Security-Policy` without `unsafe-inline`, `X-Content-Type-Options`, `Referrer-Policy` and `X-Frame-Options`, and are not cached once logged in. The stylesheet and the one small script are served from `/static/` with an `ETag` and cached for a year.
- In `auth.readAccess: authenticated` mode, browsers are sent to the login page instead of getting a 401. API clients are unchanged.
- Browsers get HTML pages for 403, 404 and 500. API paths answer as before.
- The router is split into route modules, registered by hand: `app.g.dart` and the `shelf_router_generator` dev dependency are gone.
- Adds the dependencies `markdown` and `html`.
- **Breaking:** the compiled AngularDart UI is gone: `/main.dart.js` answers 404, and `/`, `/packages`, `/packages/<name>` and `/packages/<name>/versions/<version>` serve the new pages. The `/webapi` endpoints and `/packages/<name>.json` stay.
- **Breaking:** `App` gains the optional argument `config`, shown on the admin settings page. The pages are part of `App.handler` and `App.router`. `authMiddleware` gains an optional `failureResponse`, and lets the login form and `/static/` through in `authenticated` mode, and a session post its own `/logout`, `/account/password` and `/account/tokens` routes like the JSON ones.
- **Breaking:** `MetaStore` gains `searchPackages` and `existingPackageNames`, with defaults that read every package through `queryPackages` and `queryPackage`. `MongoStore` overrides both.

## 3.0.0-dev.3

Completes the pub API, and adds publishing policies and an upstream proxy. See "Pub API compatibility", "Retraction and discontinued", "Publishing policies" and "Upstream proxy" in the README, and run `unpub migrate` after upgrading.

- Version listings have `archive_sha256`, `published` and `retracted`, and packages `isDiscontinued` and `replacedBy`. `latest` skips prereleases and retracted versions. Adds `GET /api/packages/<name>/advisories`.
- The hash of an archive is stored on upload. `unpub migrate` step `0002_version_sha256` backfills existing versions.
- Listings and archives have `ETag` and `Cache-Control`, and answer 304 to `If-None-Match`.
- Adds `POST /api/packages/<name>/versions/<version>/retract` and `unretract`, and `PUT /api/packages/<name>/discontinue`, for uploaders and administrators, audited. `publish.retractionWindow` limits non-administrators.
- Adds the `publish` settings `allowedNamePrefixes`, `maxArchiveBytes`, `requiredFiles`, `rejectOlderThanLatest`, `requireVersionBump` and `retractionWindow`. They run before `uploadValidator`.
- Adds `upstream.mode: proxy` with `cacheTtl`, `allowlist`, `timeout`, `maxArchiveBytes` and `maxConcurrentFetches`. Proxied metadata goes to the new `upstream_cache` collection, and archives under `upstream/` in the package store, streamed through a temporary file and verified against the upstream hash, with their digest kept in `upstream_archives`. A listing that later names another hash makes the copy be fetched again.
- Upstream hashes are normalized to lowercase. A malformed one answers 502, and so does a missing one unless `upstream.requireSha256` is off.
- Proxied archives only come from `upstream.url` and the new `upstream.allowedArchiveHosts`, with at most three redirects, each checked.
- A new name in proxy mode needs a definitive answer from the upstream, and otherwise answers 503. `upstream.allowPublishWhenUnavailable` accepts it with a warning instead.
- Adds `publish.maxUnpackedBytes`, enforced while inflating an upload. `publish.requiredFiles` only counts regular files.
- A publish of a version takes a per-version guard before reading the package, and a claim in the new `upload_reservations` collection before writing the archive, so concurrent publishes, also across instances, cannot corrupt it.
- Proxied archives are immutable objects named by their digest, `upstream/<name>/<name>-<version>-<sha256>.tar.gz`, and the record in `upstream_archives` is the only pointer to one, so several instances on one storage cannot serve bytes under another hash. Unverified archives get a weak `ETag`. Files at the `upstream/<name>/<name>-<version>.tar.gz` path of earlier development builds are ignored.
- An upstream 304 to a request without a validator is an upstream failure rather than a null check.
- A published archive is an immutable object named by its digest, `<name>/<name>-<version>-<sha256>.tar.gz`, written before the metadata that makes it reachable. A publish that stalled past its reservation cannot change another one's archive, and a crash leaves an object nothing refers to rather than a version without an archive. A version records its `archiveLayout`, `digest` or `legacy`: a digest version whose object is gone answers 404, only a legacy one is served from the legacy path, and a version from before the field existed is served from the legacy path only if that file hashes to its recorded digest. Step `0002_version_sha256` marks what it hashes in place as `legacy`. Replacing a version with `publish.requireVersionBump: false` is a compare-and-set on its hash. Adds `publish.uploadTimeout`, 10 minutes by default and below the 15 minute reservation, which is renewed once halfway.
- Adds a unique index on `packages.name`, so two first publishes of one version can no longer both succeed. The server refuses to start, naming the packages, if duplicates exist.
- Temporary files live in the reserved `.unpub-tmp/` namespace, on disk, in S3 and for the S3 proxy spool in the system temp directory. A custom layout resolving into it is rejected. Reclamation at startup and once an hour only deletes inside that namespace, and also removes objects over an hour old that no version and no `upstream_archives` record name. Counts are logged.
- Publishing, the proxy's commit and every deletion of an object hold a per-digest lock in the new `object_locks` collection, with a two minute lease renewed while held, and a publish that cannot get it within `publish.uploadTimeout` fails with a retryable error. Reclamation decides and deletes under the lock and skips a candidate whose lock is busy. The proxy confirms its lease right before storing, recording and deleting an object, and a lease that ran out leaves the archive served from the spool but neither stored nor recorded. A losing or failed upload no longer deletes anything, its object is left to reclamation.
- `unpub migrate --rerun 0002` hashes the versions an earlier run skipped.
- Archives are `private, no-store` in `authenticated` mode, and cached for 60 seconds with `publish.requireVersionBump: false`.
- `/webapi` gains `discontinuedAt`, `downloads` and `uploader` per version, and `downloads` per package.
- Adds per-version download counts in the new `version_stats` collection, reported as `downloads` by `/webapi/package/<name>/<version>`.
- `/webapi/packages` hides discontinued packages unless called with `?discontinued=true`. The `/webapi` views and the version badge use the new `latest`.
- A `HEAD` request for an archive is no longer counted as a download.
- **Breaking:** on `PackageStore`, `commitUpstream`, `upstreamCached`, `downloadUpstream` and `deleteUpstream` take the digest of the archive. New methods with defaults: `storeObject`, `objectExists`, `downloadObject`, `objectDownloadUrl`, `deleteObject`, `listObjects`, `objectModified` and `reclaimTemporary`. A store that keeps the defaults writes through `upload` to the mutable path, so it gets no immutability and no orphan reclamation.
- **Breaking:** the validator in `uploadValidator` now runs after the uploader check and the policies, so it no longer sees uploads those refuse.
- **Breaking:** `MetaStore` gains `replaceVersion`, which compares and sets on the previous hash and returns whether it won, `versionDownloads`, `setVersionRetracted`, `setDiscontinued` and an `includeDiscontinued` argument on `queryPackages`, and `addVersion` throws a `VersionExistsException` for a version that exists. `PackageStore` gains `upstreamTemporaryFile`, `commitUpstream`, `upstreamCached`, `downloadUpstream` and `deleteUpstream`, with defaults that cache nothing. `MetaStore` also gains `reserveUpload`, `releaseUpload` and `versionDownloadCounts`, with defaults. `UpstreamCacheStore` needs `readArchive`, `writeArchive`, `deleteArchive` and `objectLocks`, and `ArchiveReferences` needs `objectLocks`. `MetaStore.objectLocks` defaults to locks within the process. `Migrator` takes a `PackageStore`.

## 3.0.0-dev.2

Adds user accounts. See "Authentication" and "Upgrading from 2.x" in the README.

- Adds users with the roles `admin`, `publisher` and `reader`, personal API tokens with `read` and `publish` scopes, and web sessions with CSRF protection. Passwords are hashed with Argon2id, in pure Dart.
- Adds the JSON endpoints `/webapi/login`, `logout`, `me`, `me/password`, `tokens` and `users`, with a login rate limit per client address and per email.
- Adds `auth.admin.email` and `auth.admin.password`, which create the first administrator on a server without users, and `server.trustForwardedFor`.
- Adds the commands `unpub admin` (`create-user`, `set-password`, `set-role`, `disable`, `enable`, `list-users`, `create-token`) and `unpub migrate`, which creates placeholder users from existing `uploaders`.
- Adds an audit trail in the `audit` collection and the `AuditStore` interface. An event the database refuses is now reported as a failure and logged.
- Adds `Principal.credentialKind`. A custom `Authenticator` that does not set it is treated as an API token.
- Creating a user, setting a password and `PATCH /webapi/users/<id>` need a password login and answer 403 `session_required` to every kind of token.
- Revoking another user's token needs a password login. An administrator's token and `auth.bootstrapToken` get 403 `session_required`, and any other token 404. The audit event records the owner of the token and how the actor authenticated.
- The server and `unpub admin` log the MongoDB version and refuse anything older than 3.6, the oldest release `mongo_dart` can write to.
- The last enabled administrator is protected by one authoritative document in the new `admin_set` collection, updated atomically so that it cannot lose its last id, shared by the server and `unpub admin`, and rebuilt from `users` at startup. Trying to remove the last one answers 409 `last_admin`.
- Changes of a role or disabled state of an existing user write the admin set first and then the user (a user created as an administrator is inserted first and then joins the set), conditional on the state they were decided on, and run again if it changed. A promotion waits for a removal of the same user under way (409 `admin_change_in_progress`). An admin set that keeps changing under the retries answers 409 `conflict`. The README lists what the guard does not cover.
- A session holds only the scopes of its role. Every method other than GET, HEAD and OPTIONS needs a credential that can publish, except a session on its own logout, password and token routes.
- The login rate limit never forgets a locked counter or one close to the limit, and answers 429 to new addresses and emails when it has no room left.
- `/healthz` and `/readyz` are exempt from authentication with a trailing slash too.
- **Breaking:** `auth.bootstrapToken` now acts as an administrator and `auth.readTokens` as readers. Both still work but are deprecated. `auth.readAccess: authenticated` no longer needs either of them.
- **Breaking:** publishing to, or managing the uploaders of, a package without an `uploaders` list is now reserved to administrators.
- **Breaking:** a credential that is valid but not allowed to publish now gets 403 instead of 401, so that `dart pub` keeps the token.
- **Breaking:** `Authenticator.authenticate` returns null for a request without an accepted credential. `StaticTokenAuthenticator` replaces `BootstrapTokenAuthenticator` and `ReadTokenAuthenticator`, and `App.readAccess` replaces `App.readAuthenticator`.
- An administrator publishing to someone else's package no longer joins its `uploaders`. Uploader emails are matched ignoring case and new ones are stored in lowercase.
- Security: CORS responses no longer allow credentialed requests.

## 3.0.0-dev.1

Requires Dart 3. See "Upgrading from 2.x" in the README.

- **Breaking:** configuration moves to `unpub.yaml` with `UNPUB_<SECTION>_<KEY>` overrides. The command line is now `unpub serve`, `unpub version` and `unpub --help`.
- **Breaking:** publishing and uploader management need `auth.bootstrapToken`. Removes `UPLOAD_TOKEN`, `UPLOAD_EMAIL`, `ALLOWED_TOKENS` and the Google token lookup.
- **Breaking:** a registry that used `ALLOWED_TOKENS` must set `auth.readAccess: authenticated` and `auth.readTokens` to stay private. Adds both settings. In that mode every route except `/healthz` and `/readyz` needs a Bearer token.
- **Breaking:** package names must match `[a-z_][a-z0-9_]*` with at most 64 characters, and versions must be semantic versions. Other values are rejected on upload and answered with 404 on every route.
- **Breaking:** every method other than GET, HEAD and OPTIONS requires authentication by default.
- **Breaking:** `App` takes an `authenticator` and `publicUrl`, and no longer takes `googleapisProxy`, `overrideUploaderEmail` or `proxy_origin`. The `proxy-origin` header is ignored.
- Folds the S3 store into this package and removes `unpub_aws`, `unpub_web` and `unpub_auth`.
- Adds `/healthz`, `/readyz`, structured text or JSON logging and graceful shutdown.
- Adds a Docker image and Compose files.
- Security: fixes path traversal through package names and versions into the file and S3 stores.
- Security: Mongo credentials are removed from logs, `/readyz` and startup errors, and `mongo.uri` is fully validated at startup.
- `/readyz` now proves storage is writable by writing and deleting a probe, and no longer creates a missing storage directory. The directory is created once at startup.
- Explicit S3 keys no longer pick up an ambient `AWS_SESSION_TOKEN`. Credentials are never combined across sources.
- Missing archives return 404 instead of a broken response, and only served downloads are counted. Adds `PackageStore.exists`.
- Daily `stats` counters are now created on the first download.
- Keyword search treats the keyword as literal text and ignores case.
- Uploader management returns 403 for a missing package or uploaders list.

## 2.0.0

- Supports NNBD
- Fixes Web styles

## 1.2.1

## 1.2.0

- Supports mongodb pool connection
- Update web page styles

## 1.1.0

- Add badges for version and downloads
- Fix web page styles

## 1.0.0

## 0.4.0

## 0.3.0

## 0.2.2

## 0.2.1

## 0.2.0

- Refactor
- Semver whitelist

## 0.1.1

- Get email via Google APIs
- Upload validator

## 0.1.0

- `pub get`
- `pub publish` with permission check

## 0.0.1

- Initial version, created by Stagehand
