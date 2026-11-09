## 3.0.0-dev.2

Adds user accounts. See "Authentication" and "Upgrading from 2.x" in the README.

- Adds users with the roles `admin`, `publisher` and `reader`, personal API tokens with `read` and `publish` scopes, and web sessions with CSRF protection. Passwords are hashed with Argon2id, in pure Dart.
- Adds the JSON endpoints `/webapi/login`, `logout`, `me`, `me/password`, `tokens` and `users`, with a login rate limit per client address and per email.
- Adds `auth.admin.email` and `auth.admin.password`, which create the first administrator on a server without users, and `server.trustForwardedFor`.
- Adds the commands `unpub admin` (`create-user`, `set-password`, `set-role`, `disable`, `enable`, `list-users`, `create-token`) and `unpub migrate`, which creates placeholder users from existing `uploaders`.
- Adds an audit trail in the `audit` collection and the `AuditStore` interface. An event the database refuses is now reported as a failure and logged.
- Adds `Principal.credentialKind`. A custom `Authenticator` that does not set it is treated as an API token.
- Creating a user, setting a password and `PATCH /webapi/users/<id>` need a password login and answer 403 `session_required` to every kind of token.
- The last enabled administrator is protected by one authoritative document in the new `admin_set` collection, updated atomically so that it cannot lose its last id, shared by the server and `unpub admin`, and rebuilt from `users` at startup. Trying to remove the last one answers 409 `last_admin`.
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
