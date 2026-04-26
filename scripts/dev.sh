#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

if [ ! -f .env ]; then
  cp .env.example .env
  echo "Created .env from .env.example"
fi

if command -v docker >/dev/null 2>&1; then
  echo "Starting local dependency containers: redis, oracle19c"
  docker compose up -d redis oracle19c
else
  echo "Docker is not available. Make sure Oracle and Redis are reachable from .env."
fi

if ! command -v yarn >/dev/null 2>&1; then
  if command -v corepack >/dev/null 2>&1; then
    corepack enable
  fi
fi

yarn install --frozen-lockfile
yarn dev
