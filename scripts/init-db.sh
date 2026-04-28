#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

SQL_FILE=${SQL_FILE:-doc/neko_tribe-oracle-v2.sql}
ORACLE_CONTAINER_NAME=${ORACLE_CONTAINER_NAME:-oracle19c}

if [ ! -f "$SQL_FILE" ]; then
  echo "SQL file not found: $SQL_FILE" >&2
  exit 1
fi

load_env() {
  if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    . ./.env
    set +a
  fi
}

wait_for_oracle_ready() {
  container_name=$1
  attempts=60
  count=1

  while [ "$count" -le "$attempts" ]; do
    if docker exec "$container_name" sh -lc "echo 'SELECT 1 FROM dual;' | sqlplus -s / as sysdba" | grep -q "1"; then
      echo "Oracle is ready."
      return 0
    fi
    echo "Waiting for Oracle DB ready ($count/$attempts)..."
    count=$((count + 1))
    sleep 5
  done

  echo "Oracle DB not ready in time." >&2
  return 1
}

run_with_docker_oracle() {
  container_name=$1
  target=/tmp/neko_tribe-oracle-v2.sql

  wait_for_oracle_ready "$container_name"
  docker cp "$SQL_FILE" "$container_name:$target"
  docker exec -i "$container_name" sh -lc "sqlplus -s \"/ as sysdba\"" <<EOF
  ALTER PLUGGABLE DATABASE ORCLPDB1 OPEN;
  ALTER SESSION SET CONTAINER = ORCLPDB1;
  @$target
  EXIT;
EOF
}

run_with_local_sqlplus() {
  if ! command -v sqlplus >/dev/null 2>&1; then
    echo "sqlplus is not available and Oracle container '$ORACLE_CONTAINER_NAME' is not running." >&2
    echo "Start docker compose oracle19c or install SQL*Plus/SQLcl and set ORACLE_* variables." >&2
    exit 1
  fi

  : "${ORACLE_HOST:?ORACLE_HOST is required}"
  : "${ORACLE_PORT:?ORACLE_PORT is required}"
  : "${ORACLE_PWD:?ORACLE_PWD is required for SYSDBA initialization}"

  service_name=${ORACLE_SYS_SERVICE_NAME:-ORCLCDB}
  connect_string="sys/${ORACLE_PWD}@${ORACLE_HOST}:${ORACLE_PORT}/${service_name} as sysdba"

  sqlplus -s "$connect_string" @"$SQL_FILE"
}

load_env

if command -v docker >/dev/null 2>&1 \
  && docker ps --format '{{.Names}}' | grep -Eq "^${ORACLE_CONTAINER_NAME}$"; then
  run_with_docker_oracle "$ORACLE_CONTAINER_NAME"
else
  run_with_local_sqlplus
fi

echo "Database initialization finished."
