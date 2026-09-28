#!/usr/bin/env bash
set -Eeuo pipefail

OLD_VERSION="${OLD_VERSION:-0.26.2}"
OLD_IMAGE="${OLD_IMAGE:-docker.io/neosmemo/memos:0.26.2@sha256:3eefcc231141369accbd2f42bdc1a4c1e3b291fb6e288ff0deb60afa1b5d4727}"

latest_stable_version() {
  git ls-remote --tags https://github.com/usememos/memos.git 'refs/tags/v*' |
    awk -F/ '{print $3}' |
    sed 's/\^{}$//' |
    grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' |
    sed 's/^v//' |
    sort -Vu |
    tail -n 1
}

NEW_VERSION="${NEW_VERSION:-$(latest_stable_version)}"
NEW_IMAGE="${NEW_IMAGE:-docker.io/neosmemo/memos:${NEW_VERSION}}"
TEST_ROOT="${TEST_ROOT:-$(mktemp -d)}"
DATA_DIR="$TEST_ROOT/data"
CONTAINER_NAME="memos-upgrade-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-$$"

mkdir -p "$DATA_DIR"
chmod 0777 "$DATA_DIR"

cleanup() {
  docker rm --force "$CONTAINER_NAME" >/dev/null 2>&1 || true
  if [[ "${KEEP_UPGRADE_TEST_DATA:-false}" != "true" ]]; then
    rm -rf "$TEST_ROOT" 2>/dev/null || sudo -n rm -rf "$TEST_ROOT" 2>/dev/null || true
  else
    echo "Upgrade test data retained at $TEST_ROOT"
  fi
}
trap cleanup EXIT

on_error() {
  local code="$1"
  local command="$2"
  local line="$3"
  echo "::error title=Memos upgrade test failed::line $line: $command (exit $code)" >&2
  docker logs "$CONTAINER_NAME" 2>&1 | tail -n 120 || true
  return "$code"
}
trap 'on_error "$?" "$BASH_COMMAND" "$LINENO"' ERR

start_memos() {
  local image="$1"
  docker rm --force "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker run --detach --name "$CONTAINER_NAME" \
    --publish 127.0.0.1::5230 \
    --env MEMOS_ADDR=0.0.0.0 \
    --env MEMOS_PORT=5230 \
    --env MEMOS_DRIVER=sqlite \
    --env MEMOS_DATA=/var/opt/memos \
    --volume "$DATA_DIR:/var/opt/memos" \
    "$image" >/dev/null

  local port deadline
  port="$(docker port "$CONTAINER_NAME" 5230/tcp | awk -F: 'NR == 1 {print $NF}')"
  deadline=$((SECONDS + 180))
  while (( SECONDS < deadline )); do
    if curl --fail --silent --show-error "http://127.0.0.1:${port}/healthz" > /dev/null 2>&1; then
      printf '%s\n' "$port"
      return 0
    fi
    if [[ "$(docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME")" != "true" ]]; then
      docker logs "$CONTAINER_NAME" >&2
      return 1
    fi
    sleep 2
  done
  docker logs "$CONTAINER_NAME" >&2
  echo "Timed out waiting for Memos at port $port" >&2
  return 1
}

make_data_writable() {
  docker run --rm --user 0:0 --entrypoint chown \
    --volume "$DATA_DIR:/var/opt/memos" \
    "$OLD_IMAGE" -R "$(id -u):$(id -g)" /var/opt/memos
}

database_value() {
  local expression="$1"
  python3 - "$DATA_DIR/memos_prod.db" "$expression" <<'PY'
import json
import sqlite3
import sys

database, expression = sys.argv[1:]
connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
try:
    if expression == "schema":
        row = connection.execute("SELECT value FROM system_setting WHERE name = 'BASIC'").fetchone()
        if row is None:
            raise SystemExit("BASIC system setting was not found")
        print(json.loads(row[0]).get("schemaVersion", ""))
    elif expression == "marker":
        row = connection.execute("SELECT value FROM lazycat_upgrade_test WHERE id = 1").fetchone()
        print("" if row is None else row[0])
    else:
        raise SystemExit(f"unknown expression: {expression}")
finally:
    connection.close()
PY
}

echo "Pulling Memos upgrade images"
docker pull "$OLD_IMAGE" >/dev/null
docker pull "$NEW_IMAGE" >/dev/null

echo "Starting Memos $OLD_VERSION"
old_port="$(start_memos "$OLD_IMAGE")"
curl --fail --silent --show-error "http://127.0.0.1:${old_port}/" >/dev/null
docker stop "$CONTAINER_NAME" >/dev/null
make_data_writable

before_schema="$(database_value schema)"
[[ -n "$before_schema" ]] || { echo "Old schema version is empty" >&2; exit 1; }

python3 - "$DATA_DIR/memos_prod.db" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
try:
    connection.execute("CREATE TABLE IF NOT EXISTS lazycat_upgrade_test (id INTEGER PRIMARY KEY, value TEXT NOT NULL)")
    connection.execute("INSERT OR REPLACE INTO lazycat_upgrade_test (id, value) VALUES (1, 'created-on-0.26.2')")
    connection.commit()
finally:
    connection.close()
PY
printf 'created-on-0.26.2\n' > "$DATA_DIR/lazycat-upgrade-marker.txt"

echo "Upgrading Memos $OLD_VERSION -> $NEW_VERSION"
new_port="$(start_memos "$NEW_IMAGE")"
curl --fail --silent --show-error "http://127.0.0.1:${new_port}/" >/dev/null
docker stop "$CONTAINER_NAME" >/dev/null

after_schema="$(database_value schema)"
marker="$(database_value marker)"
[[ "$marker" == "created-on-0.26.2" ]] || { echo "SQLite marker was not preserved" >&2; exit 1; }
grep -qx 'created-on-0.26.2' "$DATA_DIR/lazycat-upgrade-marker.txt"

python3 - "$before_schema" "$after_schema" <<'PY'
import sys

def version(value: str) -> tuple[int, ...]:
    return tuple(int(part) for part in value.split("."))

before, after = sys.argv[1:]
if version(after) < version(before):
    raise SystemExit(f"schema version decreased: {before} -> {after}")
PY

echo "Restarting Memos $NEW_VERSION with the migrated directory"
restart_port="$(start_memos "$NEW_IMAGE")"
curl --fail --silent --show-error "http://127.0.0.1:${restart_port}/healthz" >/dev/null

echo "Upgrade verified: $OLD_VERSION -> $NEW_VERSION; schema $before_schema -> $after_schema; SQLite data and persistent files survived restart."
