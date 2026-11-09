## 3.0.0-dev.1

Requires Dart 3. See "Upgrading from 2.x" in the README.

- **Breaking:** configuration moves to `unpub.yaml` with `UNPUB_<SECTION>_<KEY>` overrides. The command line is now `unpub serve`, `unpub version` and `unpub --help`.
- **Breaking:** publishing and uploader management need `auth.bootstrapToken`. Removes `UPLOAD_TOKEN`, `UPLOAD_EMAIL`, `ALLOWED_TOKENS` and the Google token lookup.
- **Breaking:** `App` takes an `authenticator` and `publicUrl`, and no longer takes `googleapisProxy`, `overrideUploaderEmail` or `proxy_origin`. The `proxy-origin` header is ignored.
- Folds the S3 store into this package and removes `unpub_aws`, `unpub_web` and `unpub_auth`.
- Adds `/healthz`, `/readyz`, structured text or JSON logging and graceful shutdown.
- Adds a Docker image and Compose files.

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
