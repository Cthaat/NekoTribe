#!/usr/bin/env bash
set -euo pipefail

# Only the fixed Oracle V2 baseline is supported; this is not a migration runner.
SQL_FILE=${SQL_FILE:-/opt/oracle/init/neko_tribe-oracle-v2.sql}
ORACLE_HOST=${ORACLE_HOST:-oracle19c}
ORACLE_PORT=${ORACLE_PORT:-1521}
ORACLE_SYS_SERVICE_NAME=${ORACLE_SYS_SERVICE_NAME:-ORCLCDB}
ORACLE_PDB_NAME=${ORACLE_PDB_NAME:-ORCLPDB1}
DB_INIT_SCHEMA=${DB_INIT_SCHEMA:-${ORACLE_USER:-NEKO_APP}}
DB_INIT_CHECK_TABLE=${DB_INIT_CHECK_TABLE:-N_USERS}
: "${ORACLE_PWD:?ORACLE_PWD is required for database initialization}"

fail() { echo "$1" >&2; exit 1; }
[[ "${ORACLE_PDB_NAME^^}" == ORCLPDB1 && "${DB_INIT_SCHEMA^^}" == NEKO_APP && "${DB_INIT_CHECK_TABLE^^}" == N_USERS ]] || fail 'Baseline requires ORCLPDB1 / NEKO_APP / N_USERS.'
[[ "${ORACLE_SERVICE_NAME:-ORCLPDB1}" == ORCLPDB1 ]] || fail 'Baseline requires ORCLPDB1.'
[[ "$ORACLE_SYS_SERVICE_NAME" =~ ^[A-Za-z][A-Za-z0-9_#\$]*$ && "$ORACLE_HOST" =~ ^[A-Za-z0-9_.:-]+$ && "$ORACLE_PORT" =~ ^[0-9]+$ ]] || fail 'Invalid Oracle connection values.'
[[ "$ORACLE_PWD" != *\"* && "$ORACLE_PWD" != *$'\n'* && "$ORACLE_PWD" != *$'\r'* ]] || fail 'Password cannot contain double quotes or line breaks.'
[[ "$SQL_FILE" != *\"* && "$SQL_FILE" != *$'\n'* && "$SQL_FILE" != *$'\r'* && -f "$SQL_FILE" ]] || fail 'Invalid or missing SQL file.'
command -v sqlplus >/dev/null 2>&1 || fail 'sqlplus is required.'

# Capture output because SQLPlus may echo a failed CONNECT command containing credentials.
# No password appears in the process command line.
sql_session() {
  local body=$1 output
  if ! output=$(sqlplus -L -s /nolog 2>&1 <<SQL
WHENEVER OSERROR EXIT FAILURE ROLLBACK
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET ECHO OFF VERIFY OFF DEFINE OFF FEEDBACK OFF HEADING OFF PAGESIZE 0
CONNECT sys/"${ORACLE_PWD}"@//${ORACLE_HOST}:${ORACLE_PORT}/${ORACLE_SYS_SERVICE_NAME} AS SYSDBA
ALTER SESSION SET CONTAINER = ORCLPDB1;
${body}
EXIT;
SQL
  ); then
    fail 'SQLPlus failed; initialization stopped (SQL output suppressed).'
  fi
  if printf '%s\n' "$output" | grep -Eq '(ORA-|SP2-|TNS-)[0-9]{4,5}'; then
    fail 'SQLPlus reported an error; initialization stopped (SQL output suppressed).'
  fi
  printf '%s\n' "$output"
}

occupied="(SELECT COUNT(*) FROM dba_users WHERE username IN ('NEKO_APP','NEKO_ADMIN','NEKO_READONLY')) + (SELECT COUNT(*) FROM dba_tablespaces WHERE tablespace_name IN ('NEKO_DATA','NEKO_INDEX','NEKO_TEMP'))"
output=$(sql_session "SELECT 'NEKO_STATE:' || CASE WHEN EXISTS (SELECT 1 FROM dba_tables WHERE owner='NEKO_APP' AND table_name='N_USERS') THEN 'EXISTING' WHEN ($occupied)=0 THEN 'EMPTY' ELSE 'BLOCKED' END FROM dual;")
state=$(printf '%s\n' "$output" | tr -d '\r' | sed -n 's/^[[:space:]]*NEKO_STATE:\([A-Z]*\)[[:space:]]*$/\1/p')
case "$state" in
  EXISTING) echo 'Existing N_USERS marker found; skipping baseline (not a schema completeness check).'; exit 0 ;;
  EMPTY) ;;
  *) fail 'Target is occupied or its state is unknown; refusing initialization.' ;;
esac
[[ "${DB_INIT_ALLOW_EMPTY:-false}" == true ]] || fail 'Empty target: set DB_INIT_ALLOW_EMPTY=true explicitly to initialize.'
sql_session "DECLARE n NUMBER; BEGIN SELECT $occupied INTO n FROM dual; IF n <> 0 THEN RAISE_APPLICATION_ERROR(-20001,'Target is not empty'); END IF; END;
/
@\"$SQL_FILE\"" >/dev/null
echo 'Database initialization finished.'
