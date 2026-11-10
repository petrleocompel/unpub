#!/usr/bin/env bash
# The end-to-end smoke test of the web client against the real server.
#
# Builds the client, starts MongoDB (unless UNPUB_E2E_MONGO_URI points to
# one, as in CI), starts the Dart server with the build as ui.assetsDir,
# publishes ui/e2e/fixtures/e2e_demo through the pub API, and runs the
# Playwright tests in ui/e2e. Cleans up after itself.
#
#   npm run test:e2e                     # everything
#   UNPUB_E2E_SKIP_BUILD=1 npm run test:e2e
#   npm run test:e2e -- --headed         # arguments go to playwright test
#
# With UNPUB_E2E_SCREENSHOTS=1 (npm run screenshots) it runs
# e2e/screenshots.spec.ts instead: the server accepts webhooks to
# http://127.0.0.1, the spec seeds its own registry, and the fixture is not
# published here.
set -euo pipefail

ui_dir="$(cd "$(dirname "$0")/.." && pwd)"
repo_dir="$(cd "$ui_dir/.." && pwd)"
port="${UNPUB_E2E_PORT:-4123}"
base_url="http://localhost:$port"
screenshots="${UNPUB_E2E_SCREENSHOTS:-}"
admin_email="admin@e2e.example"
admin_password="e2e-admin-password"
if [[ -n "$screenshots" ]]; then
  admin_email="ada.lovelace@company.example"
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/unpub-e2e.XXXXXX")"
mongo_container=""
server_pid=""

cleanup() {
  status=$?
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  if [[ -n "$mongo_container" ]]; then
    docker rm -f "$mongo_container" >/dev/null 2>&1 || true
  fi
  if [[ $status -ne 0 && -f "$work/server.log" ]]; then
    echo "--- server log (last 80 lines) ---" >&2
    tail -n 80 "$work/server.log" >&2
  fi
  rm -rf "$work"
  exit $status
}
trap cleanup EXIT INT TERM

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }

if [[ -z "${UNPUB_E2E_SKIP_BUILD:-}" ]]; then
  log "Building the client"
  (cd "$ui_dir" && npm run build --silent)
fi
test -f "$ui_dir/dist/index.html"

if [[ -n "${UNPUB_E2E_MONGO_URI:-}" ]]; then
  mongo_uri="$UNPUB_E2E_MONGO_URI"
else
  log "Starting MongoDB"
  mongo_container="unpub-e2e-mongo-$$"
  docker run -d --rm --name "$mongo_container" -p 127.0.0.1::27017 mongo:7 >/dev/null
  mongo_port="$(docker port "$mongo_container" 27017/tcp | head -n1 | sed 's/.*://')"
  mongo_uri="mongodb://127.0.0.1:$mongo_port/unpub_e2e"
  for _ in $(seq 1 60); do
    docker exec "$mongo_container" mongosh --quiet --eval 'db.adminCommand("ping").ok' >/dev/null 2>&1 && break
    sleep 1
  done
fi

cat >"$work/unpub.yaml" <<YAML
server:
  host: 127.0.0.1
  port: $port
mongo:
  uri: $mongo_uri
storage:
  type: file
  file:
    path: $work/packages
auth:
  admin:
    email: $admin_email
    password: $admin_password
ui:
  assetsDir: $ui_dir/dist
  mode: spa
logging:
  level: warning
YAML
if [[ -n "$screenshots" ]]; then
  # The spec runs a receiver on 127.0.0.1, and one webhook points at a closed
  # port so that its deliveries fail at the first attempt.
  cat >>"$work/unpub.yaml" <<YAML
webhooks:
  allowHttp: true
  allowPrivateNetworks: true
  maxAttempts: 1
YAML
fi

log "Starting the server on $base_url"
(cd "$repo_dir/unpub" && dart pub get --enforce-lockfile >/dev/null)
(cd "$repo_dir/unpub" && exec dart run bin/unpub.dart serve --config "$work/unpub.yaml") >"$work/server.log" 2>&1 &
server_pid=$!
for _ in $(seq 1 120); do
  curl -fsS "$base_url/readyz" >/dev/null 2>&1 && break
  kill -0 "$server_pid" 2>/dev/null || { echo "The server exited" >&2; exit 1; }
  sleep 0.5
done
curl -fsS "$base_url/readyz" >/dev/null

if [[ -n "$screenshots" ]]; then
  log "Taking the screenshots"
  cd "$ui_dir"
  UNPUB_E2E_BASE_URL="$base_url" \
    UNPUB_E2E_ADMIN_EMAIL="$admin_email" \
    UNPUB_E2E_ADMIN_PASSWORD="$admin_password" \
    UNPUB_E2E_SCREENSHOTS=1 \
    npx playwright test --project=screenshots "$@"
  exit 0
fi

log "Publishing the fixture package"
jar="$work/cookies"
csrf="$(curl -fsS -c "$jar" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$admin_email\",\"password\":\"$admin_password\"}" \
  "$base_url/webapi/login" | sed -E 's/.*"csrfToken":"([^"]+)".*/\1/')"
token="$(curl -fsS -b "$jar" -H 'Content-Type: application/json' -H "X-CSRF-Token: $csrf" \
  -d '{"name":"e2e-publish","scopes":["read","publish"],"expiresIn":"1h"}' \
  "$base_url/webapi/tokens" | sed -E 's/.*"secret":"([^"]+)".*/\1/')"
COPYFILE_DISABLE=1 tar -czf "$work/e2e_demo.tar.gz" -C "$ui_dir/e2e/fixtures/e2e_demo" pubspec.yaml README.md CHANGELOG.md LICENSE lib
upload_url="$(curl -fsS -H "Authorization: Bearer $token" "$base_url/api/packages/versions/new" |
  sed -E 's/.*"url":"([^"]+)".*/\1/')"
finish="$(curl -fsS -o /dev/null -w '%{redirect_url}' -H "Authorization: Bearer $token" \
  -F "file=@$work/e2e_demo.tar.gz" "$upload_url")"
case "$finish" in
  *error=*) echo "Publishing failed: $finish" >&2; exit 1 ;;
esac
curl -fsS -H "Authorization: Bearer $token" "$finish" >/dev/null

log "Running Playwright"
cd "$ui_dir"
UNPUB_E2E_BASE_URL="$base_url" \
  UNPUB_E2E_ADMIN_EMAIL="$admin_email" \
  UNPUB_E2E_ADMIN_PASSWORD="$admin_password" \
  npx playwright test "$@"
