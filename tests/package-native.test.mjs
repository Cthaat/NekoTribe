import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { copyFile, cp, mkdir, mkdtemp, readFile, rm, rmdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { nativeTarget, packageNative, verifyNative } from '../scripts/package-native.mjs';

test('a release directory preserves target metadata and detects a modified payload', async t => {
  const folder = await mkdtemp(join(tmpdir(),'native-package-'));
  const input = join(folder,'fixture');
  const output = join(folder,'release');
  t.after(async () => {
    const names = ['nekotribe-rust','env.example','start-native.mjs','package-native.mjs','check-deployment-endpoints.mjs','runtime-addresses.md','native-package.json','start.cmd','start.sh'];
    await Promise.all([input,...names.map(name => join(output,name))].map(file => rm(file,{force:true})));
    await rmdir(output).catch(error => { if (error.code !== 'ENOENT') throw error; });
    await rmdir(folder);
  });
  const elf = Buffer.alloc(64);
  elf.set([0x7f,0x45,0x4c,0x46,2,1,1]);
  elf.writeUInt16LE(3,16);
  elf.writeUInt16LE(183,18);
  await writeFile(input,elf);
  const packaged = await packageNative('rust',input,output);
  assert.deepEqual(await verifyNative(output),packaged);
  assert.deepEqual(await nativeTarget(join(output,packaged.executable)),{os:'linux',arch:'arm64'});
  if (process.platform !== 'linux' || process.arch !== 'arm64') {
    const check = spawnSync(process.execPath, [join(output,'start-native.mjs'),'--check'],{cwd:folder,encoding:'utf8'});
    assert.equal(check.status,1);
    assert.match(check.stderr,/targets linux-arm64/);
  }
  await assert.rejects(() => packageNative('rust',input,output),{code:'EEXIST'});
  const example = join(output,'env.example');
  const original = await readFile(example,'utf8');
  await writeFile(example,`${original}\n# changed after copy\n`);
  await assert.rejects(() => verifyNative(output),/PACKAGE_HASH_MISMATCH/);
});

test('a standalone backend checkout can launch and package from a renamed directory', async t => {
  const folder = await mkdtemp(join(tmpdir(),'native standalone-'));
  t.after(() => rm(folder,{recursive:true,force:true}));
  const source = join(folder,'checkout');
  const scripts = fileURLToPath(new URL('../scripts/',import.meta.url));
  await mkdir(join(source,'scripts'),{recursive:true});
  for (const name of ['start-native.mjs','package-native.mjs','check-deployment-endpoints.mjs']) {
    await copyFile(join(scripts,name),join(source,'scripts',name));
  }
  await cp(join(scripts,'release'),join(source,'scripts/release'),{recursive:true});
  await mkdir(join(source,'contracts'));
  await writeFile(join(source,'Cargo.toml'),'[package]\nname = "fixture"\nversion = "0.1.0"\n');
  await writeFile(join(source,'env.example'),'fixture template\n');
  await writeFile(join(source,'contracts/runtime-addresses.md'),'fixture addresses\n');

  const launcher = join(source,'scripts/start-native.mjs');
  const {prepareNativeLaunch} = await import(pathToFileURL(launcher));
  const launch = prepareNativeLaunch(['rust','--check'],{
    ACCESS_SECRET:'fixture',REFRESH_SECRET:'fixture',ORACLE_HOST:'db.example.test',
    ORACLE_SERVICE_NAME:'APP',ORACLE_USER:'fixture',ORACLE_PASSWORD:'fixture',
  });
  assert.equal(launch.cwd,source);
  assert.equal(launch.command,'cargo');
  const local = Object.entries({ ...launch.env, RUST_BACKEND_PORT:'30113' })
    .map(([key,value])=>`${key}=${value}`).join('\n');
  await writeFile(join(source,'.env.rust'),local);
  await writeFile(join(folder,'.env.rust'),local.replace('30113','31113'));
  const automatic = prepareNativeLaunch(['--check'],{});
  assert.equal(automatic.backend,'rust');
  assert.equal(automatic.cwd,source);
  assert.equal(automatic.port,30113);
  assert.equal(prepareNativeLaunch(['--check','--env-file',join(folder,'.env.rust')],{}).port,31113);
  const checked = spawnSync(process.execPath,[launcher,'--check'],{cwd:folder,encoding:'utf8',env:{}});
  assert.equal(checked.status,0,checked.stderr);
  assert.match(checked.stdout,/configuration checked for port 30113/);

  const input = join(folder,'fixture');
  const output = join(folder,'release');
  const elf = Buffer.alloc(64);
  elf.set([0x7f,0x45,0x4c,0x46,2,1,1]);
  elf.writeUInt16LE(3,16);
  elf.writeUInt16LE(62,18);
  await writeFile(input,elf);
  const pack = spawnSync(process.execPath,[join(source,'scripts/package-native.mjs'),'rust','--binary',input,'--out',output],
    {cwd:source,encoding:'utf8'});
  assert.equal(pack.status,0,pack.stderr);
  assert.equal(await readFile(join(output,'runtime-addresses.md'),'utf8'),'fixture addresses\n');
  assert.equal((await verifyNative(output)).backend,'rust');
});

test('packaged launcher locates the backend, optional ffprobe and private config', async t => {
  const os = process.platform;
  if (!['win32','linux'].includes(os) || !['x64','arm64'].includes(process.arch)) return t.skip('no native package for this host');
  const folder = await mkdtemp(join(tmpdir(),'native release launcher-'));
  const input = join(folder,'fixture');
  const output = join(folder,'release');
  const executable = os === 'win32' ? 'nekotribe-go.exe' : 'nekotribe-go';
  const ffprobe = os === 'win32' ? 'ffprobe.exe' : 'ffprobe';
  const envFile = join(output,'.env.go');
  t.after(async () => {
    const names = [executable,ffprobe,'env.example','start-native.mjs','package-native.mjs','check-deployment-endpoints.mjs','runtime-addresses.md','native-package.json','.env.go','start.cmd','start.sh'];
    await Promise.all([input,...names.map(name=>join(output,name))].map(file=>rm(file,{force:true})));
    await rmdir(output).catch(error=>{if(error.code!=='ENOENT') throw error;});
    await rmdir(folder);
  });
  const header = Buffer.alloc(88);
  if (os === 'win32') {
    header.write('MZ');
    header.writeUInt32LE(64,60);
    header.writeUInt32LE(0x4550,64);
    header.writeUInt16LE(process.arch === 'x64' ? 0x8664 : 0xaa64,68);
    header.writeUInt16LE(2,86);
  } else {
    header.set([0x7f,0x45,0x4c,0x46,2,1,1]);
    header.writeUInt16LE(3,16);
    header.writeUInt16LE(process.arch === 'x64' ? 62 : 183,18);
  }
  await writeFile(input,header);
  const packageScript = fileURLToPath(new URL('../scripts/package-native.mjs',import.meta.url));
  const pack = spawnSync(process.execPath,[packageScript,'go','--binary',input,'--out',output,'--ffprobe',input],{encoding:'utf8'});
  assert.equal(pack.status,0,pack.stderr);
  const packaged = await verifyNative(output);
  assert.equal(packaged.ffprobe,ffprobe);
  assert.equal(packaged.version,4);
  await writeFile(envFile,[
    'ACCESS_SECRET=fixture-access','REFRESH_SECRET=fixture-refresh','ORACLE_HOST=db.example.test',
    'ORACLE_SERVICE_NAME=APP','ORACLE_USER=fixture-user','ORACLE_PASSWORD=fixture-password','GO_BACKEND_PORT=33006'
  ].join('\n'));
  const inherited = Object.fromEntries(Object.entries(process.env).filter(([key]) =>
    !/^(ACCESS_SECRET|REFRESH_SECRET|ORACLE_|GO_BACKEND_PORT|PORT|FFPROBE_PATH)/i.test(key)));
  const launcher = join(output,'start-native.mjs');
  const { prepareNativeLaunch } = await import(pathToFileURL(launcher));
  assert.throws(() => prepareNativeLaunch(['skills','--plan'],inherited),/Skill maintenance support/);
  const manifest = join(output,'native-package.json');
  await writeFile(manifest,JSON.stringify({...packaged,skillMaintenance:'yes'}));
  await assert.rejects(() => verifyNative(output),/INVALID_PACKAGE_MANIFEST/);
  await writeFile(manifest,JSON.stringify({...packaged,skillMaintenance:true}));
  assert.equal((await verifyNative(output)).skillMaintenance,true);
  const maintenance = prepareNativeLaunch(['skills','--status'],inherited);
  assert.deepEqual(maintenance.args,['skills','--status']);
  assert.equal(maintenance.env.ORACLE_USER,'fixture-user');
  assert.equal(maintenance.env.FFPROBE_PATH,undefined);
  assert.equal(prepareNativeLaunch(['--check'],inherited).env.FFPROBE_PATH,join(output,ffprobe));
  assert.equal(prepareNativeLaunch(['--check'],{...inherited,FFPROBE_PATH:'custom-ffprobe'}).env.FFPROBE_PATH,'custom-ffprobe');
  const check = spawnSync(process.execPath,[launcher,'--check'],{cwd:folder,env:inherited,encoding:'utf8'});
  assert.equal(check.status,0,check.stderr);
  assert.match(check.stdout,/go native configuration checked for port 33006/);
  const [shell,args] = os === 'win32'
    ? ['cmd.exe',['/d','/c','.\\start.cmd','--check']]
    : ['sh',['start.sh','--check']];
  const wrapped = spawnSync(shell,args,{cwd:output,env:inherited,encoding:'utf8'});
  assert.equal(wrapped.status,0,wrapped.stderr);
  assert.match(wrapped.stdout,/verified\./);
  assert.match(wrapped.stdout,/go native configuration checked for port 33006/);
  await writeFile(join(output,ffprobe),Buffer.concat([header,Buffer.from([1])]));
  await assert.rejects(() => verifyNative(output),/PACKAGE_HASH_MISMATCH/);
  const damaged = spawnSync(shell,args,{cwd:output,env:inherited,encoding:'utf8'});
  assert.equal(damaged.status,1);
  assert.match(damaged.stderr,/PACKAGE_HASH_MISMATCH/);
  assert.doesNotMatch(damaged.stdout,/configuration checked/);
  await rm(join(output,ffprobe),{force:true});
  assert.throws(() => prepareNativeLaunch(['--check'],inherited),/packaged ffprobe executable is missing/);
  assert.equal(prepareNativeLaunch(['--check'],{...inherited,FFPROBE_PATH:'custom-ffprobe'}).env.FFPROBE_PATH,'custom-ffprobe');
  await rm(join(output,executable),{force:true});
  const missing = spawnSync(process.execPath,[launcher,'--check'],{cwd:folder,env:inherited,encoding:'utf8'});
  assert.equal(missing.status,1);
  assert.match(missing.stderr,/binary is missing or unreadable/);
});
