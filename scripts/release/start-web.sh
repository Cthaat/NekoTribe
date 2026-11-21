#!/usr/bin/env sh
set -eu
CDPATH= cd -- "$(dirname -- "$0")"
exec node serve-web.mjs "$@"
