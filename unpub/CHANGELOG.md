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
