#!/usr/bin/env sh
set -eu
CDPATH= cd -- "$(dirname -- "$0")"
node package-native.mjs --verify .
exec node start-native.mjs "$@"
