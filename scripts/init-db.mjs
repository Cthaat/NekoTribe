import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseEnv } from 'node:util';

const rootDirectory = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const sqlSettings = 'WHENEVER OSERROR EXIT FAILURE ROLLBACK\nWHENEVER SQLERROR EXIT FAILURE ROLLBACK\nSET ECHO OFF VERIFY OFF DEFINE OFF FEEDBACK OFF HEADING OFF PAGESIZE 0\n';
const occupied = `(SELECT COUNT(*) FROM dba_users WHERE username IN ('NEKO_APP','NEKO_ADMIN','NEKO_READONLY')) + (SELECT COUNT(*) FROM dba_tablespaces WHERE tablespace_name IN ('NEKO_DATA','NEKO_INDEX','NEKO_TEMP'))`;

export function initializeDatabase({ root = rootDirectory, env = process.env, run = spawnSync } = {}) {
  const envFile = resolve(root, '.env');
  const config = { ...(existsSync(envFile) ? parseEnv(readFileSync(envFile, 'utf8')) : {}), ...env };
  for (const [key, expected] of Object.entries({ ORACLE_PDB_NAME: 'ORCLPDB1', ORACLE_SERVICE_NAME: 'ORCLPDB1', DB_INIT_SCHEMA: 'NEKO_APP', ORACLE_USER: 'NEKO_APP', DB_INIT_CHECK_TABLE: 'N_USERS' })) {
    if (config[key] && config[key].toUpperCase() !== expected) throw new Error(`${key} must be ${expected} for this fixed baseline.`);
  }
  const sqlFile = resolve(root, config.SQL_FILE || 'data/neko_tribe-oracle-v2.sql');
  if (!existsSync(sqlFile)) throw new Error('Baseline SQL file not found.');
  if (/["\r\n]/.test(sqlFile)) throw new Error('Unsupported SQL filename.');
  const container = config.ORACLE_CONTAINER_NAME;
  const sid = config.ORACLE_SYS_SERVICE_NAME || 'ORCLCDB';
  if (!/^[A-Za-z][A-Za-z0-9_$#]*$/.test(sid)) throw new Error('Invalid Oracle SID/service.');
  function checked(command, args, input) {
    const result = run(command, args, { cwd: root, env: config, input, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, windowsHide: true });
    // Never echo SQLPlus output: it can contain a failed CONNECT command/password.
    if (result.error || result.status !== 0 || /(?:ORA-|SP2-|TNS-)\d{4,5}/.test(result.stdout || '')) throw new Error(`${command} failed; initialization stopped (SQL output suppressed).`);
    return result.stdout || '';
  }
  let connect;
  if (container) {
    if (!/^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(container)) throw new Error('Invalid container name.');
    connect = 'CONNECT / AS SYSDBA\n';
  } else {
    for (const key of ['ORACLE_HOST', 'ORACLE_PORT', 'ORACLE_PWD']) if (!config[key]) throw new Error(`${key} is required; set ORACLE_CONTAINER_NAME explicitly for container execution.`);
    if (!/^[A-Za-z0-9_.:-]+$/.test(config.ORACLE_HOST) || !/^\d+$/.test(config.ORACLE_PORT) || /["\r\n]/.test(config.ORACLE_PWD)) throw new Error('Unsupported Oracle connection value; passwords cannot contain double quotes or line breaks.');
    connect = `CONNECT sys/"${config.ORACLE_PWD}"@//${config.ORACLE_HOST}:${config.ORACLE_PORT}/${sid} AS SYSDBA\n`;
  }
  const prefix = sqlSettings + connect + 'ALTER SESSION SET CONTAINER = ORCLPDB1;\n';
  const execute = sql => container
    ? checked('docker', ['exec', '-i', '-e', `ORACLE_SID=${sid}`, container, 'sqlplus', '-L', '-s', '/nolog'], sql)
    : checked('sqlplus', ['-L', '-s', '/nolog'], sql);
  const output = execute(prefix + `SELECT 'NEKO_STATE:' || CASE WHEN EXISTS (SELECT 1 FROM dba_tables WHERE owner='NEKO_APP' AND table_name='N_USERS') THEN 'EXISTING' WHEN (${occupied})=0 THEN 'EMPTY' ELSE 'BLOCKED' END FROM dual;\nEXIT;\n`);
  const states = output.split(/\r?\n/).map(line => line.trim()).filter(line => line.startsWith('NEKO_STATE:'));
  if (states.length !== 1) throw new Error('Cannot determine target state; no SQL executed.');
  if (states[0] === 'NEKO_STATE:EXISTING') { console.log('Existing N_USERS marker found; skipping baseline (not a schema completeness check).'); return; }
  if (states[0] !== 'NEKO_STATE:EMPTY') throw new Error('Target contains baseline users/tablespaces; refusing initialization.');
  if (config.DB_INIT_ALLOW_EMPTY !== 'true') throw new Error('Empty target: set DB_INIT_ALLOW_EMPTY=true explicitly to initialize.');
  const target = container ? `/tmp/nekotribe-init-${process.pid}.sql` : sqlFile;
  if (container) checked('docker', ['cp', sqlFile, `${container}:${target}`]);
  try {
    execute(prefix + `DECLARE n NUMBER; BEGIN SELECT ${occupied} INTO n FROM dual; IF n <> 0 THEN RAISE_APPLICATION_ERROR(-20001,'Target is not empty'); END IF; END;\n/\n@"${target}"\nEXIT;\n`);
  } finally {
    if (container) checked('docker', ['exec', container, 'rm', '-f', target]);
  }
  console.log('Database initialization finished.');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { initializeDatabase(); } catch (error) { console.error(error.message); process.exitCode = 1; }
}
