import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

// Explicit opt-in: never pulls an image, mounts data, or accesses the network.
test('Linux shell syntax and SQLPlus stub matrix', { skip: process.env.NEKO_TEST_SHELL_CONTAINER !== 'true' }, () => {
  const files = ['dev.sh', 'start.sh', 'init-db.sh', 'docker-init-db.sh'];
  let script = 'set -eu\nmkdir -p /tmp/fixture/bin\ncd /tmp/fixture\n';
  for (const file of files) script += `cat > '${file}' <<'NEKO_SCRIPT_EOF'\n${readFileSync(new URL('../scripts/' + file, import.meta.url), 'utf8')}\nNEKO_SCRIPT_EOF\n${file === 'docker-init-db.sh' ? 'bash' : 'sh'} -n '${file}'\n`;
  script += String.raw`
cat > bin/sqlplus <<'STUB_EOF'
#!/bin/bash
set -eu
[[ "$*" != *fixture-secret* ]] || exit 90
body=$(cat)
printf '%s\n' "$body" >> /tmp/sql-calls
if [[ "$body" == *"SELECT 'NEKO_STATE:'"* ]]; then
  if [[ "$STATE" == ERROR ]]; then echo 'ORA-01017: failed'; exit 1; fi
  printf 'NEKO_STATE:%s\n' "$STATE"
else
  [[ "$body" == *RAISE_APPLICATION_ERROR* ]] || exit 91
  [[ "$body" == *'WHENEVER SQLERROR EXIT FAILURE ROLLBACK'* ]] || exit 92
  if [[ "$FAIL_BASELINE" == true ]]; then exit 1; fi
  touch /tmp/baseline-called
fi
STUB_EOF
chmod +x bin/sqlplus
export PATH="/tmp/fixture/bin:$PATH" SQL_FILE=/tmp/fixture/baseline.sql ORACLE_PWD=fixture-secret FAIL_BASELINE=false
touch "$SQL_FILE"
for scenario in EXISTING BLOCKED ERROR UNKNOWN EMPTY; do
  export STATE=$scenario DB_INIT_ALLOW_EMPTY=false
  rm -f /tmp/sql-calls /tmp/baseline-called
  if bash docker-init-db.sh >/tmp/result 2>&1; then
    [[ "$STATE" == EXISTING ]] || exit 93
  else
    [[ "$STATE" != EXISTING ]] || exit 94
  fi
  [[ ! -f /tmp/baseline-called ]] || exit 95
  ! grep -q fixture-secret /tmp/result || exit 96
done
export STATE=EMPTY DB_INIT_ALLOW_EMPTY=true
bash docker-init-db.sh
[[ -f /tmp/baseline-called ]] || exit 97
export FAIL_BASELINE=true
rm -f /tmp/baseline-called
if bash docker-init-db.sh >/tmp/result 2>&1; then exit 100; fi
[[ ! -f /tmp/baseline-called ]] || exit 101
export FAIL_BASELINE=false
export ORACLE_PDB_NAME=WRONG
rm -f /tmp/sql-calls
if bash docker-init-db.sh >/tmp/result 2>&1; then exit 98; fi
[[ ! -f /tmp/sql-calls ]] || exit 99
echo SHELL_SAFETY_PASS
`;
  const result = spawnSync('docker', ['run', '--rm', '-i', '--pull=never', '--network=none', '--entrypoint', '/bin/bash', 'container-registry.oracle.com/os/oraclelinux:9-slim'], { input: script, encoding: 'utf8', timeout: 60000, windowsHide: true });
  assert.equal(result.status, 0, `${result.error || ''}\n${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout, /SHELL_SAFETY_PASS/);
});
