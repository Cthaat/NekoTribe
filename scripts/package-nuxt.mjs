import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { createReadStream } from 'node:fs';
import { copyFile, lstat, mkdir, readFile, readdir, readlink, symlink, writeFile } from 'node:fs/promises';
import { dirname, join, posix, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const manifestName = 'nuxt-package.json';
const usage = 'Usage: node package-nuxt.mjs --out NEW_DIR | --verify DIR | --prepare DIR';
const dependencies = '.output/server/node_modules/';
const supportFiles = ['.env.example','doc/runtime-addresses.md','scripts/run-nuxt.mjs',
  'scripts/runtime-env.mjs','scripts/package-nuxt.mjs'];
const launchers = ['start.cmd','start.sh'];
const migrationFiles = ['scripts/migrate-db.mjs','server/database/schema.mjs','server/database/schema-definition.mjs'];
const endpointCheck = 'scripts/check-deployment-endpoints.mjs';
const schemaBaseline = 'data/nekotribe-schema-only.sql';
const schemaInitializer = 'scripts/init-db.mjs';
const packageVersion = 6;

function filesForVersion(version) {
  return [
    ...supportFiles,
    ...(version >= 2 ? launchers : []),
    ...(version >= 3 ? migrationFiles : []),
    ...(version >= 4 ? [endpointCheck] : []),
    ...(version >= 5 ? [schemaBaseline] : []),
    ...(version >= 6 ? [schemaInitializer] : []),
  ];
}

async function inventory(directory, prefix = '.output/', items = {dirs:new Set(),files:[],links:{}}) {
  if (!(await lstat(join(directory,prefix))).isDirectory()) throw Error('UNSUPPORTED_BUILD_FILE');
  items.dirs.add(prefix.slice(0,-1));
  for (const item of await readdir(join(directory,prefix),{withFileTypes:true})) {
    const name = `${prefix}${item.name}`;
    if (item.isDirectory()) await inventory(directory,`${name}/`,items);
    else if (item.isFile()) items.files.push(name);
    else if (item.isSymbolicLink()) {
      const target = await readlink(join(directory,name));
      items.links[name] = relative(directory,resolve(directory,posix.dirname(name),target)).split(sep).join('/');
    }
    else throw Error('UNSUPPORTED_BUILD_FILE');
  }
  return items;
}

function validateLinks(links, items) {
  if (!links || typeof links !== 'object' || Array.isArray(links)) throw Error('INVALID_NUXT_PACKAGE');
  for (const [name,target] of Object.entries(links)) {
    if (!name.startsWith(dependencies) || /[\\:]/.test(name) ||
        name.split('/').some(part => !part || part === '.' || part === '..') ||
        !items.dirs.has(posix.dirname(name)) || items.dirs.has(name) || items.files.includes(name) ||
        typeof target !== 'string' || !target.startsWith(dependencies) || !items.dirs.has(target)) {
      throw Error('UNSUPPORTED_BUILD_LINK');
    }
  }
  for (const [name,target] of Object.entries(items.links)) {
    if (links[name] !== target) throw Error('PACKAGE_LINK_MISMATCH');
  }
}

async function fileHash(path) {
  if (!(await lstat(path)).isFile()) throw Error('PACKAGE_FILE_INVALID');
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest('hex');
}

async function hashes(directory, outputFiles, version) {
  if (!outputFiles.includes('.output/server/index.mjs')) throw Error('BUILD_ENTRY_MISSING');
  const files = {};
  for (const path of [...filesForVersion(version),...outputFiles.sort()]) files[path] = await fileHash(join(directory,path));
  return files;
}

export function buildEnvironment(inherited) {
  const keep = new Set(['PATH','PATHEXT','SYSTEMROOT','WINDIR','COMSPEC','OS','TMP','TEMP','TMPDIR',
    'HOME','USERPROFILE','LOCALAPPDATA','APPDATA','LANG','LC_ALL']);
  const env = Object.fromEntries(Object.entries(inherited).filter(([key]) => keep.has(key.toUpperCase())));
  return {...env,NODE_ENV:'production',NUXT_TELEMETRY_DISABLED:'1'};
}

export function buildHeapMiB(value = '4096') {
  if (!/^\d{4,5}$/.test(value) || Number(value) < 2048 || Number(value) > 32768) {
    throw Error('INVALID_NUXT_BUILD_HEAP');
  }
  return Number(value);
}

export async function copyNuxtOutput(project, output) {
  const items = await inventory(project);
  validateLinks(items.links,items);
  for (const name of items.dirs) await mkdir(join(output,name));
  for (const name of items.files) await copyFile(join(project,name),join(output,name));
  for (const name of [...supportFiles,...migrationFiles,endpointCheck,schemaBaseline,schemaInitializer]) {
    const target = join(output,name);
    await mkdir(dirname(target),{recursive:true});
    await copyFile(join(project,name),target);
  }
  for (const name of launchers) await copyFile(join(project,'scripts','release','nuxt',name),join(output,name));
  const manifest = {version:packageVersion,platform:process.platform,arch:process.arch,
    files:await hashes(output,items.files,packageVersion),links:items.links};
  await writeFile(join(output,manifestName),`${JSON.stringify(manifest,null,2)}\n`,{flag:'wx'});
  return manifest;
}

export async function verifyNuxt(output, prepare = false) {
  const path = join(output,manifestName);
  const info = await lstat(path);
  if (!info.isFile() || info.size > 16*1024*1024) throw Error('INVALID_NUXT_PACKAGE');
  const manifest = JSON.parse(await readFile(path,'utf8'));
  if (![1,2,3,4,5,6].includes(manifest?.version) || typeof manifest.platform !== 'string' || typeof manifest.arch !== 'string') {
    throw Error('INVALID_NUXT_PACKAGE');
  }
  const items = await inventory(output);
  validateLinks(manifest.links,items);
  const expected = await hashes(output,items.files,manifest.version);
  if (Object.keys(manifest.files ?? {}).length !== Object.keys(expected).length ||
      Object.keys(expected).some(name => expected[name] !== manifest.files[name])) throw Error('PACKAGE_HASH_MISMATCH');
  if (prepare) {
    if (manifest.platform !== process.platform || manifest.arch !== process.arch) throw Error('PACKAGE_PLATFORM_MISMATCH');
    for (const [name,target] of Object.entries(manifest.links)) {
      if (Object.hasOwn(items.links,name)) continue;
      const path = join(output,name);
      const targetPath = join(output,target);
      await symlink(process.platform === 'win32' ? targetPath : relative(dirname(path),targetPath),path,
        process.platform === 'win32' ? 'junction' : 'dir');
    }
  }
  return manifest;
}

async function packageNuxt(output) {
  const heap = buildHeapMiB(process.env.NEKO_NUXT_BUILD_HEAP_MB);
  // Reserve the destination so a failed run cannot overwrite an earlier release.
  await mkdir(output);
  const build = spawnSync(process.execPath,[`--max-old-space-size=${heap}`,
    'node_modules/nuxt/bin/nuxt.mjs','build','--dotenv','.env.example'],{
    cwd:root,env:buildEnvironment(process.env),stdio:'inherit',shell:false,
  });
  if (build.error || build.status !== 0) throw Error('NUXT_BUILD_FAILED');
  return copyNuxtOutput(root,output);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [mode,path,...extra] = process.argv.slice(2);
  try {
    if (!path || extra.length || !['--out','--verify','--prepare'].includes(mode)) throw Error(usage);
    const manifest = await (mode === '--out' ? packageNuxt(resolve(path)) : verifyNuxt(resolve(path),mode === '--prepare'));
    console.info(`Nuxt ${manifest.platform}-${manifest.arch} ${mode === '--out' ? 'packaged' : mode === '--prepare' ? 'prepared' : 'verified'}.`);
  } catch (error) {
    console.error(error.code === 'EEXIST' ? 'Output directory already exists.' :
      error.message === usage || /^[A-Z_]+$/.test(error.message) ? error.message : 'Nuxt package operation failed.');
    process.exitCode = 1;
  }
}
