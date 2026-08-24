#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PATH="$ROOT/bin:$PATH"
TMP="${TMPDIR:-/tmp}/inter-env-test.$$"
PORT=$((18080 + ($$ % 1000)))
SERVER_URL="http://127.0.0.1:$PORT/testtoken"
SERVER_PID=""

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
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

mkdir -p "$TMP"
SERVER_ENTRY="$ROOT/dist/index.js"
[ -f "$SERVER_ENTRY" ] || fail "missing compiled server; run yarn build"

INTER_ENV_SERVER_DATA="$TMP/server-data" INTER_ENV_SERVER_TOKEN="testtoken" PORT="$PORT" node "$SERVER_ENTRY" >"$TMP/server.log" 2>&1 &
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

mkdir -p "$TMP/device-a-repo/apps/api" "$TMP/device-a-repo/packages/web"
printf 'ONE=1\n' >"$TMP/device-a-repo/.env.local"
printf 'API_ONE=1\n' >"$TMP/device-a-repo/apps/api/.env"
printf 'WEB_ONE=1\n' >"$TMP/device-a-repo/packages/web/.env.local"

INTER_ENV_HOME="$TMP/device-a-home" INTER_ENV_NO_START=1 interenv init --fresh --server "$SERVER_URL" "$TMP/device-a-repo" >/dev/null

code=$(INTER_ENV_HOME="$TMP/device-a-home" interenv pair | awk '/Pairing code:/ {print $3}')
[ -n "$code" ] || fail "pairing code was not generated"

INTER_ENV_HOME="$TMP/device-b-home" INTER_ENV_NO_START=1 interenv init --link --server "$SERVER_URL" --code "$code" "$TMP/device-b-repo" >/dev/null
assert_file_contains "$TMP/device-b-repo/.env.local" "ONE=1"
assert_file_contains "$TMP/device-b-repo/apps/api/.env" "API_ONE=1"
assert_file_contains "$TMP/device-b-repo/packages/web/.env.local" "WEB_ONE=1"

if find "$TMP/server-data" -type f -name 'env.bin' -print | grep -q .; then
  fail "server kept env blob after both devices acknowledged the first revision"
fi

printf 'TWO=2\n' >"$TMP/device-b-repo/.env.local"
printf 'API_TWO=2\n' >"$TMP/device-b-repo/apps/api/.env"
mkdir -p "$TMP/device-b-repo/services/worker"
printf 'WORKER_TWO=2\n' >"$TMP/device-b-repo/services/worker/.env.production"
INTER_ENV_HOME="$TMP/device-b-home" interenv sync "$TMP/device-b-repo"

if ! find "$TMP/server-data" -type f -name 'env.bin' -print | grep -q .; then
  fail "server deleted env blob before device-a pulled the second revision"
fi

INTER_ENV_HOME="$TMP/device-a-home" interenv pull "$TMP/device-a-repo" >/dev/null
assert_file_contains "$TMP/device-a-repo/.env.local" "TWO=2"
assert_file_contains "$TMP/device-a-repo/apps/api/.env" "API_TWO=2"
assert_file_contains "$TMP/device-a-repo/services/worker/.env.production" "WORKER_TWO=2"

if find "$TMP/server-data" -type f -name 'env.bin' -print | grep -q .; then
  fail "server kept env blob after both devices acknowledged the second revision"
fi

if find "$TMP/server-data" -type f -name 'env.bin' -exec grep -q 'TWO=2' {} \; -print | grep -q .; then
  fail "server stored plaintext env contents"
fi

printf 'PASS\n'
