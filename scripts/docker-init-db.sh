#!/usr/bin/env bash
set -euo pipefail

SQL_FILE=${SQL_FILE:-/opt/oracle/init/neko_tribe-oracle-v2.sql}
ORACLE_HOST=${ORACLE_HOST:-oracle19c}
ORACLE_PORT=${ORACLE_PORT:-1521}
ORACLE_SYS_SERVICE_NAME=${ORACLE_SYS_SERVICE_NAME:-ORCLCDB}
ORACLE_PDB_NAME=${ORACLE_PDB_NAME:-ORCLPDB1}
DB_INIT_SCHEMA=${DB_INIT_SCHEMA:-${ORACLE_USER:-neko_app}}
DB_INIT_CHECK_TABLE=${DB_INIT_CHECK_TABLE:-N_USERS}

: "${ORACLE_PWD:?ORACLE_PWD is required for database initialization}"

if [ ! -f "$SQL_FILE" ]; then
  echo "SQL file not found: $SQL_FILE" >&2
  exit 1
fi

if ! command -v sqlplus >/dev/null 2>&1; then
  echo "sqlplus is not available in this image." >&2
  exit 1
fi

for value_name in ORACLE_PDB_NAME DB_INIT_SCHEMA DB_INIT_CHECK_TABLE; do
  value=${!value_name}
  if [[ ! "$value" =~ ^[A-Za-z][A-Za-z0-9_#\$]*$ ]]; then
    echo "Invalid $value_name: $value" >&2
    exit 1
  fi
done

SYS_CONNECT_STRING="sys/${ORACLE_PWD}@//${ORACLE_HOST}:${ORACLE_PORT}/${ORACLE_SYS_SERVICE_NAME} as sysdba"

wait_for_oracle() {
  local attempt
  local output

  for attempt in $(seq 1 90); do
    if output=$(sqlplus -L -s "$SYS_CONNECT_STRING" <<'SQL'
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF
SELECT 'NEKOTRIBE_ORACLE_READY' FROM dual;
EXIT;
SQL
    ) && printf '%s\n' "$output" | grep -q 'NEKOTRIBE_ORACLE_READY'; then
      echo "Oracle is ready."
      return 0
    fi

    echo "Waiting for Oracle DB ready ($attempt/90)..."
    sleep 10
  done

  echo "Oracle DB not ready in time." >&2
  return 1
}

ensure_pdb_open() {
  local attempt
  local open_mode
  local output

  for attempt in $(seq 1 90); do
    if output=$(sqlplus -L -s "$SYS_CONNECT_STRING" <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF
SELECT COALESCE(MAX(open_mode), 'MISSING')
FROM v\$pdbs
WHERE name = UPPER('${ORACLE_PDB_NAME}');
EXIT;
SQL
    ); then
      open_mode=$(printf '%s\n' "$output" | tr -d '\r' | awk 'NF { print; exit }' | xargs)

      if [ "$open_mode" = "READ WRITE" ]; then
        echo "PDB ${ORACLE_PDB_NAME} is ready."
        return 0
      fi

      if [ "$open_mode" != "MISSING" ] && [ -n "$open_mode" ]; then
        if ! sqlplus -L -s "$SYS_CONNECT_STRING" <<SQL >/dev/null
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER PLUGGABLE DATABASE ${ORACLE_PDB_NAME} OPEN;
ALTER PLUGGABLE DATABASE ${ORACLE_PDB_NAME} SAVE STATE;
EXIT;
SQL
        then
          echo "PDB ${ORACLE_PDB_NAME} exists with open mode ${open_mode}, but is not open yet."
        fi
      fi
    fi

    echo "Waiting for PDB ${ORACLE_PDB_NAME} ready ($attempt/90)..."
    sleep 10
  done

  echo "PDB ${ORACLE_PDB_NAME} not ready in time." >&2
  return 1
}

is_database_initialized() {
  local output

  output=$(sqlplus -L -s "$SYS_CONNECT_STRING" <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF
ALTER SESSION SET CONTAINER = ${ORACLE_PDB_NAME};
SELECT COUNT(*)
FROM all_tables
WHERE owner = UPPER('${DB_INIT_SCHEMA}')
  AND table_name = UPPER('${DB_INIT_CHECK_TABLE}');
EXIT;
SQL
  )

  printf '%s\n' "$output" | grep -Eq '^[[:space:]]*[1-9][0-9]*[[:space:]]*$'
}

run_baseline_sql() {
  sqlplus -L -s "$SYS_CONNECT_STRING" <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET DEFINE OFF
SET SERVEROUTPUT ON
@${SQL_FILE}
EXIT;
SQL
}

wait_for_oracle
ensure_pdb_open

if is_database_initialized; then
  echo "Database schema ${DB_INIT_SCHEMA}.${DB_INIT_CHECK_TABLE} already exists. Skipping initialization."
  exit 0
fi

echo "Initializing Oracle database from ${SQL_FILE}..."
run_baseline_sql
echo "Database initialization finished."
