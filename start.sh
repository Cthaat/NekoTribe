#!/usr/bin/env sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec node "$project_dir/scripts/start-native.mjs" "$@"
