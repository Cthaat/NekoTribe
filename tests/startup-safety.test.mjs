import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { initializeDatabase } from '../scripts/init-db.mjs';
import { startApplication } from '../scripts/startup.mjs';

function fixture(fn) {
  const root = mkdtempSync(join(tmpdir(), 'neko-startup-'));
  mkdirSync(join(root, 'data'));
  writeFileSync(join(root, 'data/neko_tribe-oracle-v2.sql'), '-- fixture baseline');
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
