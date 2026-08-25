#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PATH="$ROOT/bin:$PATH"
TMP="${TMPDIR:-/tmp}/inter-env-test.$$"
PORT=$((18080 + ($$ % 1000)))
SERVER_URL="http://127.0.0.1:$PORT/testtoken"
SERVER_PID=""
WATCHER_PID=""

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$WATCHER_PID" ]; then
    kill "$WATCHER_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file_contains() {
  file=$1
  expected=$2
  [ -f "$file" ] || fail "missing file $file"
  actual=$(cat "$file")
  [ "$actual" = "$expected" ] || fail "expected $file to contain '$expected', got '$actual'"
}

assert_file_lacks() {
  file=$1
  unexpected=$2
  [ -f "$file" ] || fail "missing file $file"
  grep -q "$unexpected" "$file" && fail "expected $file not to contain '$unexpected'"
  return 0
}

mkdir -p "$TMP"
HOME="$TMP/user-home"
export HOME
mkdir -p "$HOME"
[ "$(interenv version)" = "0.8.0" ] || fail "unexpected CLI version"
SERVER_ENTRY="$ROOT/dist/index.js"
[ -f "$SERVER_ENTRY" ] || fail "missing compiled server; run yarn build"

INTER_ENV_SERVER_DATA="$TMP/server-data" INTER_ENV_SERVER_TOKEN="testtoken" INTER_ENV_MAX_PROJECTS=1 PORT="$PORT" node "$SERVER_ENTRY" >"$TMP/server.log" 2>&1 &
SERVER_PID=$!

i=0
while [ "$i" -lt 50 ]; do
  if curl -fsS -H "x-inter-env-token: testtoken" "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    break
  fi
  i=$((i + 1))
  sleep 0.1
done
curl -fsS -H "x-inter-env-token: testtoken" "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 || {
  cat "$TMP/server.log" >&2
  fail "server did not start"
}

root_body=$(curl -fsS "http://127.0.0.1:$PORT/")
printf '%s\n' "$root_body" | grep -q 'inter-env' || fail "root route missing service name"
printf '%s\n' "$root_body" | grep -q 'https://interenv.bytode.dev/install.sh' || fail "root route missing install URL"
printf '%s\n' "$root_body" | grep -q 'https://github.com/marvinified/interenv' || fail "root route missing repo link"
printf '%s\n' "$root_body" | grep -q 'https://bytode.dev' || fail "root route missing blog link"

curl -fsS "http://127.0.0.1:$PORT/install.sh" >"$TMP/install.sh"
grep -q '^#!/bin/sh$' "$TMP/install.sh" || fail "server did not serve install.sh"
grep -q 'https://interenv.bytode.dev/interenv' "$TMP/install.sh" || fail "served installer does not download from deployed server"

curl -fsS "http://127.0.0.1:$PORT/interenv" >"$TMP/interenv"
grep -q '^#!/bin/sh$' "$TMP/interenv" || fail "server did not serve interenv client"

git init -q "$TMP/device-a-repo"
git init -q "$TMP/device-b-repo"
git -C "$TMP/device-a-repo" remote add origin git@github.com:example/app.git
git -C "$TMP/device-b-repo" remote add origin https://github.com/example/app.git

mkdir -p "$TMP/device-a-repo/apps/api" "$TMP/device-a-repo/apps/ignored" "$TMP/device-a-repo/packages/web"
printf 'ONE=1\nLOCAL_ONLY=device-a\n' >"$TMP/device-a-repo/.env.local"
printf 'API_ONE=1\nAPI_LOCAL=device-a\n' >"$TMP/device-a-repo/apps/api/.env"
printf 'WEB_ONE=1\n' >"$TMP/device-a-repo/packages/web/.env.local"
printf 'PRIVATE=1\n' >"$TMP/device-a-repo/.env.private"
printf 'IGNORED=1\n' >"$TMP/device-a-repo/apps/ignored/.env"
printf '%s\n' \
  'file .env.private' \
  'file apps/ignored/.env*' \
  'variable LOCAL_ONLY' \
  'variable apps/*/.env API_LOCAL' >"$TMP/device-a-repo/.envignore"
cp "$TMP/device-a-repo/.envignore" "$TMP/device-b-repo/.envignore"

INTER_ENV_HOME="$TMP/device-a-home" interenv setup --fresh --server "$SERVER_URL" >/dev/null
INTER_ENV_HOME="$TMP/device-a-home" INTER_ENV_NO_START=1 interenv init "$TMP/device-a-repo" >/dev/null
INTER_ENV_HOME="$TMP/device-a-home" interenv status | grep -q '(active)' || fail "status did not report an active account"

code=$(INTER_ENV_HOME="$TMP/device-a-home" interenv pair | awk '/Pairing code:/ {print $3}')
[ -n "$code" ] || fail "pairing code was not generated"
printf '%s\n' "$code" | grep -Eq '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$' || fail "pairing code is not 6 uppercase characters"
printf 'duplicate' >"$TMP/duplicate-pair"
duplicate_status=$(curl -sS -o /dev/null -w '%{http_code}' -H "x-inter-env-token: testtoken" -X PUT --data-binary "@$TMP/duplicate-pair" "http://127.0.0.1:$PORT/v1/pair/$code")
[ "$duplicate_status" = "409" ] || fail "server did not reject an active duplicate pairing code"

printf 'STALE=local\n' >"$TMP/device-b-repo/.env.local"
INTER_ENV_HOME="$TMP/device-b-home" interenv setup --link --server "$SERVER_URL" --code "$code" >/dev/null
INTER_ENV_HOME="$TMP/device-b-home" INTER_ENV_NO_START=1 interenv init "$TMP/device-b-repo" >/dev/null
assert_file_contains "$TMP/device-b-repo/.env.local" "ONE=1"
assert_file_contains "$TMP/device-b-repo/apps/api/.env" "API_ONE=1"
assert_file_contains "$TMP/device-b-repo/packages/web/.env.local" "WEB_ONE=1"
assert_file_lacks "$TMP/device-b-repo/.env.local" "LOCAL_ONLY"
assert_file_lacks "$TMP/device-b-repo/apps/api/.env" "API_LOCAL"
[ ! -f "$TMP/device-b-repo/.env.private" ] || fail "ignored env file was synced"
[ ! -f "$TMP/device-b-repo/apps/ignored/.env" ] || fail "ignored nested env file was synced"

share_command=$(INTER_ENV_HOME="$TMP/device-a-home" interenv share "$TMP/device-a-repo")
share_url=$(printf '%s\n' "$share_command" | awk '/^curl -fsSL / {print $3}')
printf '%s\n' "$share_url" | grep -Eq "^http://127.0.0.1:$PORT/share.sh\?[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{12}$" || fail "share did not return a valid one-time command"
mkdir -p "$TMP/share-target"
curl -fsSL "$share_url" | sh -s -- "$TMP/share-target" >/dev/null
assert_file_contains "$TMP/share-target/.env.local" "ONE=1"
assert_file_contains "$TMP/share-target/apps/api/.env" "API_ONE=1"
assert_file_contains "$TMP/share-target/packages/web/.env.local" "WEB_ONE=1"
assert_file_lacks "$TMP/share-target/.env.local" "LOCAL_ONLY"
assert_file_lacks "$TMP/share-target/apps/api/.env" "API_LOCAL"
[ ! -f "$TMP/share-target/.env.private" ] || fail "one-time share included an ignored env file"
mkdir -p "$TMP/share-second-target"
if curl -fsSL "$share_url" 2>/dev/null | sh -s -- "$TMP/share-second-target" >/dev/null 2>&1; then
  fail "one-time share could be downloaded twice"
fi

if find "$TMP/server-data" -type f -name 'env.bin' -print | grep -q .; then
  fail "server kept env blob after both devices acknowledged the first revision"
fi

printf 'TWO=2\nLOCAL_ONLY=device-b\n' >"$TMP/device-b-repo/.env.local"
printf 'API_TWO=2\nAPI_LOCAL=device-b\n' >"$TMP/device-b-repo/apps/api/.env"
mkdir -p "$TMP/device-b-repo/services/worker"
printf 'WORKER_TWO=2\n' >"$TMP/device-b-repo/services/worker/.env.production"
INTER_ENV_HOME="$TMP/device-b-home" interenv sync "$TMP/device-b-repo"

if ! find "$TMP/server-data" -type f -name 'env.bin' -print | grep -q .; then
  fail "server deleted env blob before device-a pulled the second revision"
fi

INTER_ENV_HOME="$TMP/device-a-home" interenv sync "$TMP/device-a-repo" >/dev/null
grep -q '^TWO=2$' "$TMP/device-a-repo/.env.local" || fail "pull did not update the root env file"
grep -q '^API_TWO=2$' "$TMP/device-a-repo/apps/api/.env" || fail "pull did not update the nested env file"
assert_file_contains "$TMP/device-a-repo/services/worker/.env.production" "WORKER_TWO=2"
grep -q '^LOCAL_ONLY=device-a$' "$TMP/device-a-repo/.env.local" || fail "pull did not preserve an ignored local variable"
grep -q '^API_LOCAL=device-a$' "$TMP/device-a-repo/apps/api/.env" || fail "pull did not preserve a file-specific ignored variable"
assert_file_contains "$TMP/device-a-repo/.env.private" "PRIVATE=1"
assert_file_contains "$TMP/device-a-repo/apps/ignored/.env" "IGNORED=1"

if find "$TMP/server-data" -type f -name 'env.bin' -print | grep -q .; then
  fail "server kept env blob after both devices acknowledged the second revision"
fi

if find "$TMP/server-data" -type f -name 'env.bin' -exec grep -q 'TWO=2' {} \; -print | grep -q .; then
  fail "server stored plaintext env contents"
fi

account_id=$(sed -n "s/^ACCOUNT_ID='\([^']*\)'$/\1/p" "$TMP/device-a-home/config")
project_id=$(awk -F '\t' 'NR == 1 {print $2}' "$TMP/device-a-home/repos.tsv")
meta_url="http://127.0.0.1:$PORT/v1/accounts/$account_id/projects/$project_id/meta"
meta_before=$(curl -fsS -H "x-inter-env-token: testtoken" "$meta_url")
printf '\n' >>"$TMP/device-a-repo/apps/api/.env"
INTER_ENV_HOME="$TMP/device-a-home" interenv sync "$TMP/device-a-repo" >/dev/null
meta_after=$(curl -fsS -H "x-inter-env-token: testtoken" "$meta_url")
[ "$meta_before" = "$meta_after" ] || fail "blank line changed the canonical env hash"
printf 'TWO=2\nLOCAL_ONLY=changed-locally\n' >"$TMP/device-a-repo/.env.local"
printf 'PRIVATE=changed-locally\n' >"$TMP/device-a-repo/.env.private"
INTER_ENV_HOME="$TMP/device-a-home" interenv sync "$TMP/device-a-repo" >/dev/null
meta_after_ignore_change=$(curl -fsS -H "x-inter-env-token: testtoken" "$meta_url")
[ "$meta_before" = "$meta_after_ignore_change" ] || fail "ignored data changed the project hash"

git init -q "$TMP/device-a-new-repo"
git -C "$TMP/device-a-new-repo" remote add origin https://github.com/example/new-app.git
printf 'NEW=1\n' >"$TMP/device-a-new-repo/.env"
if INTER_ENV_HOME="$TMP/device-a-home" INTER_ENV_NO_START=1 interenv init "$TMP/device-a-new-repo" >"$TMP/project-limit.log" 2>&1; then
  fail "server allowed initialization beyond the project limit"
fi
grep -q 'project limit reached (1)' "$TMP/project-limit.log" || fail "project limit error was not actionable"

INTER_ENV_HOME="$TMP/device-a-home" interenv project delete "$TMP/device-a-repo" --yes >/dev/null
[ ! -d "$TMP/server-data/accounts/$account_id/projects/$project_id" ] || fail "project deletion kept server data"
if INTER_ENV_HOME="$TMP/device-b-home" interenv push "$TMP/device-b-repo" >/dev/null 2>&1; then
  fail "another device recreated a deleted project"
fi
INTER_ENV_HOME="$TMP/device-a-home" INTER_ENV_NO_START=1 interenv init "$TMP/device-a-new-repo" >/dev/null
new_project_id=$(awk -F '\t' 'NR == 1 {print $2}' "$TMP/device-a-home/repos.tsv")
[ -d "$TMP/server-data/accounts/$account_id/projects/$new_project_id" ] || fail "deleted project did not free a project slot"

cp -R "$TMP/device-a-home" "$TMP/failure-home"
awk '{ if ($0 ~ /^SERVER_URL=/) print "SERVER_URL=\047http://127.0.0.1:1\047"; else print }' "$TMP/failure-home/config" >"$TMP/failure-home/config.tmp"
mv "$TMP/failure-home/config.tmp" "$TMP/failure-home/config"
rm -f "$TMP/failure-home/inter-env.pid"
INTER_ENV_HOME="$TMP/failure-home" INTER_ENV_INTERVAL=1 interenv watch >/dev/null 2>&1 &
WATCHER_PID=$!
sleep 2
kill -0 "$WATCHER_PID" 2>/dev/null || fail "watcher exited after a transient server failure"
grep -q 'retrying in 1s' "$TMP/failure-home/inter-env.log" || fail "watcher did not log retry behavior"
kill "$WATCHER_PID" >/dev/null 2>&1 || true
wait "$WATCHER_PID" 2>/dev/null || true
WATCHER_PID=""

account_id=$(sed -n "s/^ACCOUNT_ID='\([^']*\)'$/\1/p" "$TMP/device-b-home/config")
[ -n "$account_id" ] || fail "account id missing from device config"
printf 'wrong-secret' >"$TMP/wrong-delete-secret"
if curl -fsS -H "x-inter-env-token: testtoken" -X DELETE --data-binary "@$TMP/wrong-delete-secret" "http://127.0.0.1:$PORT/v1/accounts/$account_id" >/dev/null 2>&1; then
  fail "server accepted an invalid account deletion secret"
fi

INTER_ENV_HOME="$TMP/device-b-home" interenv account delete --yes >/dev/null
[ ! -d "$TMP/server-data/accounts/$account_id" ] || fail "server kept account data after account deletion"
[ ! -f "$TMP/device-b-home/config" ] || fail "client kept local config after account deletion"
INTER_ENV_HOME="$TMP/device-a-home" interenv status | grep -q '(deleted)' || fail "status did not report a remotely deleted account"
printf 'AFTER_DELETE=1\n' >"$TMP/device-a-repo/.env.local"
if INTER_ENV_HOME="$TMP/device-a-home" interenv push "$TMP/device-a-repo" >/dev/null 2>&1; then
  fail "deleted account accepted an upload from another paired device"
fi
[ ! -d "$TMP/server-data/accounts/$account_id" ] || fail "paired device recreated a deleted account"

mkdir -p "$TMP/uninstall-bin"
cp "$ROOT/bin/interenv" "$TMP/uninstall-bin/interenv"
chmod +x "$TMP/uninstall-bin/interenv"
PATH="$TMP/uninstall-bin:$PATH" interenv uninstall >/dev/null
[ ! -e "$TMP/uninstall-bin/interenv" ] || fail "uninstall kept the CLI executable"

printf 'PASS\n'
