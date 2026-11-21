import assert from 'node:assert/strict';
import { mkdtemp, rm, rmdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { prepareNativeLaunch } from '../scripts/start-native.mjs';

const shared = {
  ACCESS_SECRET:'fixture-access', REFRESH_SECRET:'fixture-refresh',
  ORACLE_HOST:'db.example.test', ORACLE_SERVICE_NAME:'DBPDB',
  ORACLE_USER:'fixture-user', ORACLE_PASSWORD:'fixture-password',
};

test('explicit env layers and process overrides feed both native entry points', async t => {
  const folder = await mkdtemp(join(tmpdir(),'neko-start-native-'));
  const base = join(folder,'common.env');
  const override = join(folder,'local.env');
  t.after(async () => {
    await Promise.all([base,override].map(path => rm(path,{force:true})));
    await rmdir(folder);
  });
  await writeFile(base,Object.entries({...shared,PORT:'3999'}).map(([name,value])=>`${name}=${value}`).join('\n'));
  await writeFile(override,'GO_BACKEND_PORT=30007\nRUST_BACKEND_MODE=compat\nORACLE_USER=local-user\n');
  const files = ['--env-file',base,'--env-file',override,'--check'];

  const go = prepareNativeLaunch(['go',...files],{ORACLE_USER:'process-user'});
  assert.equal(go.check,true);
  assert.equal(go.port,30007);
  assert.equal(go.env.GO_BACKEND_PORT,'30007');
  assert.equal(go.env.ORACLE_USER,'process-user');
  assert.equal(go.command,'go');
  assert.deepEqual(go.args,['run','./cmd/server']);

  const rust = prepareNativeLaunch(['rust',...files],{RUST_BACKEND_MODE:'compat'});
  assert.equal(rust.port,3999);
  assert.equal(rust.env.RUST_BACKEND_PORT,'3999');
  assert.equal(rust.env.RUST_BACKEND_MODE,'native');
  assert.equal(rust.env.ORACLE_USER,'local-user');
  assert.equal(rust.command,'cargo');
  assert.deepEqual(rust.args,['run','--locked']);
});

test('offline validation preserves explicit binaries and rejects missing settings or ports', () => {
  const binary = prepareNativeLaunch(['go','--binary',process.execPath,'--check'],shared);
  assert.equal(binary.command,process.execPath);
  assert.equal(binary.cwd,dirname(process.execPath));
  assert.deepEqual(binary.args,[]);
  assert.equal(binary.port,30006);
  assert.equal(binary.env.GO_BACKEND_PORT,'30006');
  const rust = prepareNativeLaunch(['rust','--check'],shared);
  assert.equal(rust.port,30003);
  assert.equal(rust.env.RUST_BACKEND_PORT,'30003');
  assert.throws(() => prepareNativeLaunch(['rust','--check'],{...shared,ORACLE_PASSWORD:''}),/ORACLE_PASSWORD/);
  assert.throws(() => prepareNativeLaunch(['go','--check'],{...shared,GO_BACKEND_PORT:'99999'}),/Invalid GO_BACKEND_PORT/);
  assert.throws(() => prepareNativeLaunch(['go','--env-file'],shared),/Usage/);
  assert.throws(() => prepareNativeLaunch(['go','--check','--check-config'],shared),/Usage/);
  assert.deepEqual(prepareNativeLaunch(['go','--check-config'],shared).args,['run','./cmd/server','--check-config']);
  assert.deepEqual(prepareNativeLaunch(['rust','--check-config'],shared).args,['run','--locked','--','--check-config']);
  assert.throws(() => prepareNativeLaunch(['go','--binary',process.execPath,'--check-config'],shared),/created with --build/);
  const canonical = Object.fromEntries(Object.entries(shared).map(([key,value]) => [`NUXT_${key}`,value]));
  for (const backend of ['go','rust']) {
    assert.doesNotThrow(() => prepareNativeLaunch([backend,'--check-config'],canonical));
    assert.throws(() => prepareNativeLaunch([backend,'--check-config'],{
      ...shared,...canonical,NUXT_ORACLE_PASSWORD:'',
    }),/ORACLE_PASSWORD/);
  }
});

test('Skill maintenance only passes the maintenance arguments and skips HTTP settings', () => {
  const args = ['skills','--plan','--enabled-json','["writing-draft"]'];
  assert.deepEqual(prepareNativeLaunch(['go',...args],{}).args,['run','./cmd/server',...args]);
  const rust = prepareNativeLaunch(['rust',...args],{PORT:'invalid'});
  assert.deepEqual(rust.args,['run','--locked','--',...args]);
  assert.equal(rust.env.RUST_BACKEND_PORT,undefined);
  assert.throws(() => prepareNativeLaunch(['go','--check',...args],{}),/Usage/);
  assert.throws(() => prepareNativeLaunch(['go','--binary',process.execPath,...args],{}),/Skill maintenance support/);
});
