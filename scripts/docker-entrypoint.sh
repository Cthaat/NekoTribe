#!/usr/bin/env sh
set -eu

STORAGE_ROOT=${STORAGE_PATH:-/app/storage}
LEGACY_UPLOAD_ROOT=${LEGACY_UPLOAD_PATH:-$STORAGE_ROOT/legacy-upload}

mkdir -p \
  "$STORAGE_ROOT" \
  "$STORAGE_ROOT/temp" \
  "$LEGACY_UPLOAD_ROOT"

exec "$@"
