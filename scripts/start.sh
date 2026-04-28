#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

if [ ! -f .env ]; then
  cp .env.example .env
  echo "Created .env from .env.example"
fi

STORAGE_ROOT_DIR=${STORAGE_ROOT_DIR:-./storage}
if [ -f .env ]; then
  STORAGE_ROOT_DIR_LINE=$(
    sed -n 's/^[[:space:]]*STORAGE_ROOT_DIR[[:space:]]*=[[:space:]]*//p' .env \
      | head -n 1 \
      | tr -d '\r'
  )

  if [ -n "$STORAGE_ROOT_DIR_LINE" ]; then
    STORAGE_ROOT_DIR=$(printf '%s' "$STORAGE_ROOT_DIR_LINE" | sed "s/^[\"']//; s/[\"']$//")
  fi
fi

mkdir -p \
  "$STORAGE_ROOT_DIR" \
  "$STORAGE_ROOT_DIR/temp"

docker compose up -d --build
docker compose ps
