#!/usr/bin/env sh
set -eu

STORAGE_ROOT=${STORAGE_PATH:-/app/storage}

mkdir -p \
  "$STORAGE_ROOT" \
  "$STORAGE_ROOT/temp"

exec "$@"
