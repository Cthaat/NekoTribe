#!/bin/sh
set -eu
kit_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec node "$kit_dir/restore-workspace.mjs" "$@"
