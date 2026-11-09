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
- A published archive is an immutable object named by its digest, `<name>/<name>-<version>-<sha256>.tar.gz`, written before the metadata that makes it reachable. A publish that stalled past its reservation cannot change another one's archive, and a crash leaves an object nothing refers to rather than a version without an archive. Downloads fall back to the legacy path for versions published before this. Replacing a version with `publish.requireVersionBump: false` is a compare-and-set on its hash. Adds `publish.uploadTimeout`, 10 minutes by default and below the 15 minute reservation, which is renewed once halfway.
- Adds a unique index on `packages.name`, so two first publishes of one version can no longer both succeed. The server refuses to start, naming the packages, if duplicates exist.
- Temporary files live in the reserved `.unpub-tmp/` namespace, on disk, in S3 and for the S3 proxy spool in the system temp directory. A custom layout resolving into it is rejected. Reclamation at startup and once an hour only deletes inside that namespace, and also removes objects over an hour old that no version and no `upstream_archives` record name. Counts are logged.
- `unpub migrate --rerun 0002` hashes the versions an earlier run skipped.
- Archives are `private, no-store` in `authenticated` mode, and cached for 60 seconds with `publish.requireVersionBump: false`.
- `/webapi` gains `discontinuedAt`, `downloads` and `uploader` per version, and `downloads` per package.
- Adds per-version download counts in the new `version_stats` collection, reported as `downloads` by `/webapi/package/<name>/<version>`.
- `/webapi/packages` hides discontinued packages unless called with `?discontinued=true`. The `/webapi` views and the version badge use the new `latest`.
- A `HEAD` request for an archive is no longer counted as a download.
- **Breaking:** on `PackageStore`, `commitUpstream`, `upstreamCached`, `downloadUpstream` and `deleteUpstream` take the digest of the archive. New methods with defaults: `storeObject`, `objectExists`, `downloadObject`, `objectDownloadUrl`, `deleteObject`, `listObjects`, `objectModified` and `reclaimTemporary`. A store that keeps the defaults writes through `upload` to the mutable path, so it gets no immutability and no orphan reclamation.
- **Breaking:** the validator in `uploadValidator` now runs after the uploader check and the policies, so it no longer sees uploads those refuse.
- **Breaking:** `MetaStore` gains `replaceVersion`, which compares and sets on the previous hash and returns whether it won, `versionDownloads`, `setVersionRetracted`, `setDiscontinued` and an `includeDiscontinued` argument on `queryPackages`, and `addVersion` throws a `VersionExistsException` for a version that exists. `PackageStore` gains `upstreamTemporaryFile`, `commitUpstream`, `upstreamCached`, `downloadUpstream` and `deleteUpstream`, with defaults that cache nothing. `MetaStore` also gains `reserveUpload`, `releaseUpload` and `versionDownloadCounts`, with defaults. `UpstreamCacheStore` needs `readArchive`, `writeArchive` and `deleteArchive`. `Migrator` takes a `PackageStore`.

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
