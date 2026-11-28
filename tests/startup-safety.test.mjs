import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { initializeDatabase, initializeSchemaOnly } from '../scripts/init-db.mjs';
import { startApplication } from '../scripts/startup.mjs';

function fixture(fn) {
  const root = mkdtempSync(join(tmpdir(), 'neko-startup-'));
  mkdirSync(join(root, 'data'));
  writeFileSync(join(root, 'data/neko_tribe-oracle-v2.sql'), '-- fixture baseline');
  writeFileSync(join(root, 'data/nekotribe-schema-only.sql'), '-- fixture schema-only baseline');
  writeFileSync(join(root, '.env.example'), 'SENTIMENTFLOW_ENABLED=false\n');
  try { fn(root); } finally { rmSync(root, { recursive: true, force: true }); }
}
function runner(state = 'EMPTY', failure = 0) {
  const calls = [];
  return { calls, run(command, args, options = {}) {
    calls.push({ command, args, input: options.input });
    return { status: calls.length === failure ? 1 : 0, stdout: options.input?.includes('NEKO_STATE:') ? `NEKO_STATE:${state}\n` : '', stderr: '' };
  } };
}
const env = { ORACLE_HOST: 'test.invalid', ORACLE_PORT: '1521', ORACLE_PWD: 'test-password', DB_INIT_ALLOW_EMPTY: 'true' };

const schemaArgs = ['--dotenv', 'target setup.env'];
const schemaSettings = 'ORACLE_USER=APP_OWNER\nORACLE_HOST=db.example.test\nORACLE_PORT=1521\nORACLE_SERVICE_NAME=TEST_PDB\n';

test('schema-only init uses the explicit Oracle target and SQLPlus stdin', () => fixture(root => {
  writeFileSync(join(root, schemaArgs[1]), schemaSettings +
    'ORACLE_PASSWORD=fixture-password\nNUXT_ORACLE_HOST=::1\nNUXT_ORACLE_SERVICE_NAME=SELECTED_PDB\n');
  let calls = 0;
  initializeSchemaOnly({ root, args: schemaArgs, env: { DB_INIT_ALLOW_EMPTY: 'true', ORACLE_PASSWORD: 'fixture-runtime-password' },
    run(command, args, options) {
      calls++;
      assert.equal(command, 'sqlplus');
      assert.deepEqual(args, ['-L', '-s', '/nolog']);
      assert.equal(options.env.ORACLE_PASSWORD, undefined);
      assert.equal(options.env.NLS_LANG, 'AMERICAN_AMERICA.AL32UTF8');
      assert.match(options.input, /CONNECT APP_OWNER\/"fixture-runtime-password"@\/\/\[::1\]:1521\/SELECTED_PDB/);
      assert.doesNotMatch(options.input, /AS SYSDBA|ALTER SESSION|neko_tribe-oracle-v2/);
      assert.match(options.input, /nekotribe-schema-only\.sql"\nSELECT 'NEKO_SCHEMA_CREATED'/);
      return { status: 0, stdout: 'NEKO_SCHEMA_CREATED\n', stderr: '' };
    },
  });
  assert.equal(calls, 1);
}));

test('schema-only init requires an explicit target and rejects incomplete SQLPlus runs', () => fixture(root => {
  const config = { root, args: schemaArgs, env: {}, run: () => assert.fail('Unexpected SQLPlus invocation') };
  assert.throws(() => initializeSchemaOnly({ ...config, args: [] }), /--dotenv/);
  assert.throws(() => initializeSchemaOnly(config), /file does not exist/);
  writeFileSync(join(root, schemaArgs[1]), schemaSettings + 'ORACLE_PASSWORD=fixture-password\n');
  assert.throws(() => initializeSchemaOnly(config), /DB_INIT_ALLOW_EMPTY/);
  config.env = { DB_INIT_ALLOW_EMPTY: 'true' };
  assert.throws(() => initializeSchemaOnly({ ...config, env: { ...config.env, NUXT_ORACLE_USER: 'SYS' } }), /Invalid schema owner/);
  assert.throws(() => initializeSchemaOnly({ ...config, env: { ...config.env, NUXT_ORACLE_PORT: '65536' } }), /Invalid schema owner/);
  for (const result of [{ status: 0, stdout: '' }, { status: 0, stdout: 'NEKO_SCHEMA_CREATED', stderr: 'SP2-0310 fixture-password' }]) {
    assert.throws(() => initializeSchemaOnly({ ...config, run: () => result }), error => {
      assert.match(error.message, /did not confirm/);
      assert.doesNotMatch(error.message, /fixture-password/);
      return true;
    });
  }
}));

test('portable Oracle baseline is owner-scoped DDL with an empty-schema guard', () => {
  const sql = readFileSync(new URL('../data/nekotribe-schema-only.sql', import.meta.url), 'utf8');
  const statements = [];
  let current = '';
  let plsql = false;
  for (const line of sql.split(/\r?\n/)) {
    const text = line.trim();
    if (!current) {
      if (!text || text.startsWith('--') ||
          /^(?:WHENEVER (?:OSERROR|SQLERROR) EXIT FAILURE ROLLBACK|SET (?:ECHO OFF|VERIFY OFF|DEFINE OFF|SQLBLANKLINES ON))$/.test(text)) continue;
      if (/^CREATE UNIQUE INDEX\b/i.test(text)) {
        assert.match(text, /^CREATE UNIQUE INDEX uk_search_history_term ON n_user_search_history \(user_id, normalized_query\);$/i);
      } else {
        assert.match(text, /^(?:DECLARE|CREATE (?:OR REPLACE )?(?:TABLE|SEQUENCE|INDEX|TRIGGER|FUNCTION|PROCEDURE|VIEW|MATERIALIZED VIEW)|ALTER TABLE|COMMENT ON)\b/i);
      }
      plsql = /^(?:DECLARE|CREATE (?:OR REPLACE )?(?:TRIGGER|FUNCTION|PROCEDURE))\b/i.test(text);
    }
    current += `${line}\n`;
    if (plsql ? text === '/' : text.split('--', 1)[0].trimEnd().endsWith(';')) {
      statements.push(current);
      current = '';
    }
  }
  assert.equal(current, '');
  assert.match(statements[0], /SESSION_USER[\s\S]+CURRENT_SCHEMA[\s\S]+FROM user_objects[\s\S]+object_count <> 0/i);
  assert.match(statements.at(-1), /FROM user_objects WHERE status = 'INVALID'/i);
  assert.equal(statements.filter(statement => /^CREATE TABLE /i.test(statement)).length, 53);
  assert.equal(statements.filter(statement => /^CREATE MATERIALIZED VIEW /i.test(statement)).length, 3);
  assert.match(sql, /^CREATE TABLE n_users\s*\(/im);
  assert.doesNotMatch(sql, /\b(?:CREATE USER|IDENTIFIED BY|NEKO_ADMIN|NEKO_READONLY|TABLESPACE NEKO_(?:DATA|INDEX))\b/i);
});

test('empty target gets a second guard and secrets only on stdin', () => fixture(root => {
  const stub = runner();
  initializeDatabase({ root, env: { ...env }, run: stub.run });
  assert.equal(stub.calls.length, 2);
  assert(stub.calls.every(call => !call.args.join(' ').includes(env.ORACLE_PWD)));
  assert.match(stub.calls[1].input, /RAISE_APPLICATION_ERROR/);
  assert.match(stub.calls[1].input, /WHENEVER SQLERROR EXIT FAILURE ROLLBACK/);
}));
for (const state of ['EXISTING', 'BLOCKED', 'garbage']) test(`target ${state} cannot execute baseline`, () => fixture(root => {
  const stub = runner(state);
  if (state === 'EXISTING') initializeDatabase({ root, env: { ...env }, run: stub.run });
  else assert.throws(() => initializeDatabase({ root, env: { ...env }, run: stub.run }));
  assert.equal(stub.calls.length, 1);
}));
test('SQL check error fails closed', () => fixture(root => {
  const stub = runner('EMPTY', 1);
  assert.throws(() => initializeDatabase({ root, env: { ...env }, run: stub.run }));
  assert.equal(stub.calls.length, 1);
}));
test('empty target requires explicit opt in', () => fixture(root => {
  const stub = runner();
  assert.throws(() => initializeDatabase({ root, env: { ...env, DB_INIT_ALLOW_EMPTY: '' }, run: stub.run }));
  assert.equal(stub.calls.length, 1);
}));
test('dotenv loads before options; environment takes precedence', () => fixture(root => {
  writeFileSync(join(root, '.env'), 'ORACLE_PDB_NAME=WRONG\n');
  const stub = runner();
  assert.throws(() => initializeDatabase({ root, env: { ...env }, run: stub.run }));
  assert.equal(stub.calls.length, 0);
  initializeDatabase({ root, env: { ...env, ORACLE_PDB_NAME: 'ORCLPDB1' }, run: stub.run });
}));
test('default dev never touches Docker or overwrites existing config', () => fixture(root => {
  writeFileSync(join(root, '.env'), 'KEEP=this\n');
  const stub = runner();
  startApplication({ root, mode: 'dev', args: [], run: stub.run });
  assert(!stub.calls.some(call => call.command === 'docker'));
  assert.equal(readFileSync(join(root, '.env'), 'utf8'), 'KEEP=this\n');
}));
test('start copies config and defaults to existing dependencies', () => fixture(root => {
  const stub = runner();
  startApplication({ root, mode: 'start', args: [], run: stub.run });
  assert.equal(readFileSync(join(root, '.env'), 'utf8'), 'SENTIMENTFLOW_ENABLED=false\n');
  assert(!stub.calls.some(call => call.command === 'docker'));
}));
test('dependency startup failure stops before yarn', () => fixture(root => {
  const stub = runner('', 1);
  assert.throws(() => startApplication({ root, mode: 'dev', args: ['--dependencies'], run: stub.run }));
  assert.equal(stub.calls.length, 1);
  assert.equal(stub.calls[0].command, 'docker');
}));
test('container copy failure prevents baseline', () => fixture(root => {
  const stub = runner('EMPTY', 2);
  assert.throws(() => initializeDatabase({ root, env: { ...env, ORACLE_CONTAINER_NAME: 'isolated-fixture' }, run: stub.run }));
  assert.equal(stub.calls.length, 2);
  assert.equal(stub.calls[1].args[0], 'cp');
}));
test('baseline SQL failure is not success', () => fixture(root => {
  const stub = runner('EMPTY', 2);
  assert.throws(() => initializeDatabase({ root, env: { ...env }, run: stub.run }));
}));
test('SQLPlus zero exit status with Oracle error still fails closed', () => fixture(root => {
  assert.throws(() => initializeDatabase({ root, env: { ...env }, run: () => ({ status: 0, stdout: 'ORA-01017: login failed\nNEKO_STATE:EMPTY' }) }));
}));
