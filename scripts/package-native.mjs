import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createReadStream, existsSync } from 'node:fs';
import { chmod, copyFile, lstat, mkdir, mkdtemp, open, readFile, rename, rm, rmdir, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';

const scripts = dirname(fileURLToPath(import.meta.url));
const workspace = resolve(scripts,'../..');
const usage = 'Usage: node package-native.mjs <go|rust> --build|--binary PATH --out NEW_DIR [--ffprobe PATH] | --verify DIR';
const manifestName = 'native-package.json';
const commonFiles = ['env.example','start-native.mjs','package-native.mjs','runtime-addresses.md'];
const launchers = ['start.cmd','start.sh'];
const endpointCheck = 'check-deployment-endpoints.mjs';

function backendDirectory(backend) {
  const project = resolve(scripts, '..');
  const manifest = backend === 'go' ? 'go.mod' : 'Cargo.toml';
  return existsSync(join(project, manifest)) ? project : join(workspace, backend);
}

async function regularFile(path) {
  if (!(await lstat(path)).isFile()) throw Error('PACKAGE_FILE_INVALID');
  return path;
}

async function digest(path) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(await regularFile(path))) hash.update(chunk);
  return hash.digest('hex');
}

async function readHeader(file, length, offset) {
  const bytes = Buffer.alloc(length);
  const {bytesRead} = await file.read(bytes,0,length,offset);
  return bytes.subarray(0,bytesRead);
}

export async function nativeTarget(path) {
  const file = await open(await regularFile(path),'r');
  try {
    const header = await readHeader(file,64,0);
    if (header.length === 64 && header.subarray(0,4).equals(Buffer.from([0x7f,0x45,0x4c,0x46])) &&
        header[4] === 2 && header[5] === 1 && [0,3].includes(header[7]) && [2,3].includes(header.readUInt16LE(16))) {
      const machine = header.readUInt16LE(18);
      if (machine === 62 || machine === 183) return {os:'linux',arch:machine === 62 ? 'x64' : 'arm64'};
    }
    if (header.length === 64 && header.toString('ascii',0,2) === 'MZ') {
      const pe = await readHeader(file,24,header.readUInt32LE(60));
      if (pe.length === 24 && pe.readUInt32LE(0) === 0x4550 && (pe.readUInt16LE(22) & 0x2002) === 2) {
        const machine = pe.readUInt16LE(4);
        if (machine === 0x8664 || machine === 0xaa64) return {os:'windows',arch:machine === 0x8664 ? 'x64' : 'arm64'};
      }
    }
    throw Error('UNSUPPORTED_NATIVE_EXECUTABLE');
  } finally {
    await file.close();
  }
}

const binaryName = (backend,os) => `nekotribe-${backend}${os === 'windows' ? '.exe' : ''}`;
const probeName = os => os === 'windows' ? 'ffprobe.exe' : 'ffprobe';

async function runBuild(command, args, cwd, captureArtifact) {
  const child = spawn(command, args, {
    cwd, shell: false, stdio: ['ignore', captureArtifact ? 'pipe' : 'inherit', 'inherit'],
  });
  let executable;
  if (captureArtifact) {
    const lines = createInterface({ input: child.stdout });
    lines.on('line', line => {
      // Cargo may report artifacts from dependencies. Select the requested binary target.
      let message;
      try { message = JSON.parse(line); } catch { return; }
      if (message?.reason === 'compiler-artifact' && message.target?.name === 'nekotribe-backend' &&
          message.target.kind?.includes('bin') && typeof message.executable === 'string') {
        executable = message.executable;
      }
    });
  }
  await new Promise((resolveBuild, reject) => {
    child.once('error', error => reject(Error(error.code === 'ENOENT' ? 'NATIVE_TOOLCHAIN_NOT_FOUND' : 'NATIVE_BUILD_FAILED')));
    child.once('close', code => code === 0 ? resolveBuild() : reject(Error('NATIVE_BUILD_FAILED')));
  });
  return executable;
}

export async function buildNative(backend, output, probePath) {
  if (!['go','rust'].includes(backend)) throw Error(usage);
  const source = backendDirectory(backend);
  await regularFile(join(source, backend === 'go' ? 'go.mod' : 'Cargo.toml'));
  const existing = await lstat(output).catch(error => {
    if (error.code === 'ENOENT') return null;
    throw error;
  });
  if (existing) throw Error('OUTPUT_DIRECTORY_EXISTS');
  if (backend === 'rust') {
    const executable = await runBuild('cargo', ['build', '--locked', '--release', '--bin', 'nekotribe-backend',
      '--message-format=json-render-diagnostics'], source, true);
    if (!executable) throw Error('RUST_ARTIFACT_NOT_FOUND');
    return packageNative(backend, resolve(source, executable), output, probePath, {offlineConfigCheck:true, skillMaintenance:true});
  }

  const staging = await mkdtemp(join(dirname(output), '.native-build-'));
  const executable = join(staging, 'backend');
  try {
    await runBuild('go', ['build', '-mod=readonly', '-trimpath', '-o', executable, './cmd/server'], source, false);
    return await packageNative(backend, executable, output, probePath, {offlineConfigCheck:true, skillMaintenance:true});
  } finally {
    await rm(executable, {force:true});
    await rmdir(staging);
  }
}

async function requireTarget(path, os, arch) {
  const target = await nativeTarget(path);
  if (target.os !== os || target.arch !== arch) throw Error('PACKAGE_TARGET_MISMATCH');
}

export async function packageNative(backend, binary, output, probePath, {offlineConfigCheck = false, skillMaintenance = false} = {}) {
  if (!['go','rust'].includes(backend)) throw Error(usage);
  await nativeTarget(binary);
  await mkdir(output);
  const created = [];
  try {
    async function add(source,name) {
      const destination = join(output,name);
      created.push(destination);
      await copyFile(source,destination);
    }
    const staged = 'backend.tmp';
    const stagedPath = join(output,staged);
    await add(binary,staged);
    const {os,arch} = await nativeTarget(stagedPath);
    const executable = binaryName(backend,os);
    const destination = join(output,executable);
    await rename(stagedPath,destination);
    created.push(destination);
    if (os === 'linux') await chmod(join(output,executable),0o755);
    const source = backendDirectory(backend);
    await add(join(source,'env.example'),'env.example');
    await add(join(scripts,'start-native.mjs'),'start-native.mjs');
    await add(fileURLToPath(import.meta.url),'package-native.mjs');
    const documentedAddresses = join(scripts,'../doc/runtime-addresses.md');
    const addresses = existsSync(documentedAddresses)
      ? documentedAddresses
      : join(source,'contracts/runtime-addresses.md');
    await add(addresses,'runtime-addresses.md');
    for (const name of launchers) await add(join(scripts,'release','native',name),name);
    await add(join(scripts,endpointCheck),endpointCheck);
    const expected = [executable,...commonFiles,...launchers,endpointCheck];
    const manifest = {version:4,backend,os,arch,executable,files:{}};
    if (offlineConfigCheck) manifest.offlineConfigCheck = true;
    if (skillMaintenance) manifest.skillMaintenance = true;
    if (probePath) {
      await regularFile(probePath);
      const name = probeName(os);
      await add(probePath,name);
      const probe = join(output,name);
      await requireTarget(probe,os,arch);
      if (os === 'linux') await chmod(probe,0o755);
      manifest.ffprobe = name;
      expected.push(name);
    }
    for (const name of expected) manifest.files[name] = await digest(join(output,name));
    const path = join(output,manifestName);
    created.push(path);
    await writeFile(path,`${JSON.stringify(manifest,null,2)}\n`,{flag:'wx'});
    return manifest;
  } catch (error) {
    await Promise.allSettled(created.map(path => rm(path,{force:true})));
    await rmdir(output).catch(() => {});
    throw error;
  }
}

export async function verifyNative(output) {
  const path = await regularFile(join(output,manifestName));
  if ((await lstat(path)).size > 8192) throw Error('INVALID_PACKAGE_MANIFEST');
  const manifest = JSON.parse(await readFile(path,'utf8'));
  if (![1,2,3,4].includes(manifest?.version) || !['go','rust'].includes(manifest.backend) ||
      !['windows','linux'].includes(manifest.os) || !['x64','arm64'].includes(manifest.arch) ||
      manifest.executable !== binaryName(manifest.backend,manifest.os) ||
      (manifest.offlineConfigCheck !== undefined && manifest.offlineConfigCheck !== true) ||
      (manifest.skillMaintenance !== undefined && manifest.skillMaintenance !== true)) throw Error('INVALID_PACKAGE_MANIFEST');
  const expected = [manifest.executable,...commonFiles];
  if (manifest.version >= 3) expected.push(...launchers);
  if (manifest.version >= 4) expected.push(endpointCheck);
  if (manifest.version === 2 || (manifest.version >= 3 && manifest.ffprobe !== undefined)) {
    if (manifest.ffprobe !== probeName(manifest.os)) throw Error('INVALID_PACKAGE_MANIFEST');
    expected.push(manifest.ffprobe);
  } else if (manifest.ffprobe !== undefined) throw Error('INVALID_PACKAGE_MANIFEST');
  if (Object.keys(manifest.files ?? {}).length !== expected.length) throw Error('INVALID_PACKAGE_MANIFEST');
  for (const name of expected) {
    if (manifest.files[name] !== await digest(join(output,name))) throw Error('PACKAGE_HASH_MISMATCH');
  }
  await requireTarget(join(output,manifest.executable),manifest.os,manifest.arch);
  if (manifest.ffprobe) await requireTarget(join(output,manifest.ffprobe),manifest.os,manifest.arch);
  return manifest;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const [mode, option, ...args] = process.argv.slice(2);
    const build = option === '--build';
    const [binary, outFlag, output, ...extra] = build ? [undefined, ...args] : args;
    const hasProbe = extra.length === 2 && extra[0] === '--ffprobe' && extra[1] && !extra[1].startsWith('--');
    const probe = hasProbe ? resolve(extra[1]) : undefined;
    const result = mode === '--verify' && option && args.length === 0 ? await verifyNative(resolve(option)) :
      (build || (option === '--binary' && binary)) && outFlag === '--out' && output && (extra.length === 0 || hasProbe) ?
        (build ? await buildNative(mode, resolve(output), probe) :
          await packageNative(mode, resolve(binary), resolve(output), probe)) : null;
    if (!result) throw Error(usage);
    console.info(`${result.backend} ${result.os}-${result.arch} ${mode === '--verify' ? 'verified' : 'packaged'}.`);
  } catch (error) {
    console.error(error.code === 'EEXIST' ? 'Output directory already exists.' :
      error.message === usage || /^[A-Z_]+$/.test(error.message) ? error.message : 'Native package operation failed.');
    process.exitCode = 1;
  }
}
