#!/usr/bin/env sh
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec node "$ROOT_DIR/scripts/init-db.mjs" "$@"
