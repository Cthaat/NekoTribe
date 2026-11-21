#!/usr/bin/env sh
set -eu
CDPATH= cd -- "$(dirname -- "$0")"
node scripts/package-nuxt.mjs --prepare .
exec node scripts/run-nuxt.mjs start "$@"
