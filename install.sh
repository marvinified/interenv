#!/bin/sh

set -eu

PREFIX="${PREFIX:-/usr/local/bin}"
TARGET="$PREFIX/interenv"
RAW="${INTER_ENV_CLIENT_URL:-https://interenv.bytode.dev/interenv}"

mkdir -p "$PREFIX"

if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$RAW" -o "$TARGET"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$TARGET" "$RAW"
else
  printf 'install.sh needs curl or wget\n' >&2
  exit 1
fi

chmod +x "$TARGET"
printf 'Installed interenv to %s\n' "$TARGET"
printf 'Run "interenv setup" once, then "interenv init" inside each repo you want to sync.\n'
