import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { lstat, mkdir, mkdtemp, readFile, rm, rmdir, symlink, unlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { buildEnvironment, buildHeapMiB, copyNuxtOutput, verifyNuxt } from '../scripts/package-nuxt.mjs';
import { launcherEnvironment } from './helpers/launcher-env.mjs';

test('release build passes through system paths and excludes runtime settings', () => {
  assert.deepEqual(buildEnvironment({PATH:'fixture',ORACLE_PASSWORD:'fixture',NUXT_PUBLIC_API_BASE:'fixture'}),
    {PATH:'fixture',NODE_ENV:'production',NUXT_TELEMETRY_DISABLED:'1'});
  assert.equal(buildEnvironment({NUXT_DISABLE_SOURCEMAP:'1'}).NUXT_DISABLE_SOURCEMAP,'1');
});

test('release build heap accepts a bounded override', () => {
  assert.equal(buildHeapMiB(),4096);
  assert.equal(buildHeapMiB('6144'),6144);
  for (const value of ['','2047','32769','6e3','6144 --inspect',' 6144']) {
    assert.throws(() => buildHeapMiB(value),/INVALID_NUXT_BUILD_HEAP/);
  }
});

test('Nuxt deployment copy is independent and detects damaged output', async t => {
  const folder = await mkdtemp(join(tmpdir(),'nuxt deployment-'));
  const source = join(folder,'source');
  const output = join(folder,'output');
  const modules = '.output/server/node_modules';
  const dependency = `${modules}/.nitro/fixture-dep@1.0.0`;
  const alias = `${modules}/fixture-dep`;
  const launchers = ['start.cmd','start.sh'];
  const migration = ['scripts/migrate-db.mjs','server/database/schema.mjs','server/database/schema-definition.mjs'];
  const endpointCheck = 'scripts/check-deployment-endpoints.mjs';
  const baseline = 'data/nekotribe-schema-only.sql';
  const initializer = 'scripts/init-db.mjs';
  const maintenance = ['scripts/build-ai-public-terms.mjs','scripts/lib/ai-public-terms-build.mjs',
    'scripts/ai-public-terms-maintenance.mjs','scripts/ai-skill-config-maintenance.mjs',
    'specifications/requirements/ai-public-terms-catalog.json','.output/server/ai-terms-maintenance.cjs'];
  const templates = launchers.map(name => `scripts/release/nuxt/${name}`);
  const files = ['.output/server/index.mjs','.output/public/index.html','.env.example','doc/runtime-addresses.md',
    'scripts/run-nuxt.mjs','scripts/runtime-env.mjs','scripts/package-nuxt.mjs',endpointCheck,baseline,initializer,...migration,...maintenance,`${dependency}/marker.txt`];
  t.after(async () => {
    for (const [directory,paths] of [[source,[...files,...templates,'.env']],[output,[...files,...launchers,'nuxt-package.json','.env.runtime']]]) {
      await unlink(join(directory,alias)).catch(error => { if (error.code !== 'ENOENT') throw error; });
      for (const path of paths) await rm(join(directory,path),{force:true});
      for (const path of [dependency,`${modules}/.nitro`,modules,'.output/server','.output/public','.output','scripts/release/nuxt','scripts/release','scripts/lib','scripts','specifications/requirements','specifications','server/database','server','data','doc','']) {
        await rmdir(join(directory,path)).catch(error => { if (error.code !== 'ENOENT') throw error; });
      }
    }
    await rmdir(folder);
  });
  for (const path of [...files,...templates,'.env']) {
    const file = join(source,path);
    await mkdir(dirname(file),{recursive:true});
    await writeFile(file,`fixture ${path}`);
  }
  for (const path of ['scripts/run-nuxt.mjs','scripts/runtime-env.mjs','scripts/package-nuxt.mjs',endpointCheck,baseline,initializer,...templates,...migration]) {
    await writeFile(join(source,path),await readFile(new URL(`../${path}`,import.meta.url)));
  }
  await writeFile(join(source,'.output/server/index.mjs'),
    'import { readFileSync } from "node:fs";\n' +
    'const marker = readFileSync(new URL("./node_modules/fixture-dep/marker.txt", import.meta.url), "utf8");\n' +
    'console.log(JSON.stringify({mode:process.env.NODE_ENV,port:process.env.NUXT_ORACLE_PORT,marker}));');
  await symlink(join(source,dependency),join(source,alias),process.platform === 'win32' ? 'junction' : 'dir');
  await mkdir(output);
  const result = await copyNuxtOutput(source,output);
  assert.equal(result.version,7);
  assert.deepEqual(await verifyNuxt(output),result);
  assert.deepEqual(Object.keys(result.files).sort(),[...files,...launchers].sort());
  assert.deepEqual(result.links,{[alias]:dependency});
  await assert.rejects(lstat(join(output,alias)),{code:'ENOENT'});
  const plan = JSON.parse(execFileSync(process.execPath,['scripts/migrate-db.mjs','--plan'],{
    cwd:output,env:buildEnvironment(process.env),encoding:'utf8',
  }));
  assert.equal(plan.mode,'offline-plan');
  assert.ok(plan.plan.length > 0);
  await writeFile(join(output,'.env.runtime'),'ORACLE_PORT=1522\n');
  const [shell,args] = process.platform === 'win32'
    ? ['cmd.exe',['/d','/c','.\\start.cmd','--dotenv','.env.runtime']]
    : ['sh',['start.sh','--dotenv','.env.runtime']];
  const launched = execFileSync(shell,args,{
    cwd:output,env:launcherEnvironment(buildEnvironment(process.env)),encoding:'utf8',
  });
  assert.match(launched,/prepared\./);
  assert.deepEqual(JSON.parse(launched.trim().split(/\r?\n/).at(-1)),{mode:'production',port:'1522',marker:`fixture ${dependency}/marker.txt`});
  await verifyNuxt(output,true);
  await unlink(join(output,alias));
  await symlink(join(source,dependency),join(output,alias),process.platform === 'win32' ? 'junction' : 'dir');
  await assert.rejects(() => verifyNuxt(output,true),/PACKAGE_LINK_MISMATCH/);
  await unlink(join(output,alias));
  const baselineBytes = await readFile(join(output,baseline));
  await writeFile(join(output,baseline),'modified baseline');
  await assert.rejects(() => verifyNuxt(output),/PACKAGE_HASH_MISMATCH/);
  await writeFile(join(output,baseline),baselineBytes);
  await writeFile(join(output,'.output/public/index.html'),'changed');
  await assert.rejects(() => verifyNuxt(output),/PACKAGE_HASH_MISMATCH/);
});
