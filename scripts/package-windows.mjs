import { spawnSync } from 'node:child_process';
import { cp, lstat, mkdir, realpath, stat } from 'node:fs/promises';
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

const usage = 'Usage: node scripts/package-windows.mjs --version VERSION --out NEW_RELEASE_DIR [--require-installer]';
const project = fileURLToPath(new URL('../', import.meta.url));
const requiredFiles = [
  'nekotribe.exe', 'flutter_windows.dll', 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll',
  'data/app.so', 'data/icudtl.dat', 'data/flutter_assets/AssetManifest.bin',
];

async function requireFile(path) {
  const info = await lstat(path).catch(error => {
    if (error.code === 'ENOENT') return null;
    throw error;
  });
  if (!info?.isFile() || !info.size) throw Error(`Missing or empty Windows package file: ${path}`);
}

async function findCompiler() {
  if (process.env.INNO_SETUP_ISCC) return resolve(process.env.INNO_SETUP_ISCC);
  const roots = [process.env['ProgramFiles(x86)'], process.env.ProgramFiles].filter(Boolean);
  for (const root of roots) {
    for (const directory of ['Inno Setup 7', 'Inno Setup 6']) {
      const compiler = join(root, directory, 'ISCC.exe');
      const info = await stat(compiler).catch(error => {
        if (error.code === 'ENOENT') return null;
        throw error;
      });
      if (info?.isFile()) return compiler;
    }
  }
  return 'ISCC.exe';
}

try {
  const { values } = parseArgs({ options: {
    version: { type: 'string' }, out: { type: 'string' }, 'require-installer': { type: 'boolean' },
  } });
  const { version, out } = values;
  if (!version || !/^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(version) || !out) throw Error(usage);

  const source = await realpath(join(project, 'build/windows/x64/runner/Release'));
  const destination = join(await realpath(dirname(resolve(out))), basename(out));
  const inside = relative(source, destination);
  if (!inside || (!isAbsolute(inside) && inside !== '..' && !inside.startsWith(`..${sep}`))) {
    throw Error('The release directory must be outside the source build.');
  }
  for (const name of requiredFiles) await requireFile(join(source, name));

  await mkdir(destination);
  const portable = join(destination, 'portable');
  await cp(source, portable, {
    recursive: true,
    async filter(path) {
      const info = await lstat(path);
      if (!info.isDirectory() && !info.isFile()) {
        throw Error(`Invalid file type in the Windows build: ${path}`);
      }
      return true;
    },
  });

  const installer = `NekoTribe-${version}-windows-x64-setup`;
  const binaryVersion = /^v?(\d+\.\d+\.\d+)(?:-|$)/.exec(version)?.[1];
  const result = spawnSync(await findCompiler(), [
    `/DMyAppVersion=${version}`,
    `/DSourceDir=${portable}`,
    `/DOutputBaseFilename=${installer}`,
    ...(binaryVersion ? [`/DBinaryVersion=${binaryVersion}`] : []),
    `/O${destination}`,
    join(project, 'packaging/windows/nekotribe.iss'),
  ], { stdio: 'inherit' });

  if (result.error?.code === 'ENOENT' && !process.env.INNO_SETUP_ISCC) {
    if (values['require-installer']) throw Error('Inno Setup ISCC.exe is required for this package.');
    console.info(`Inno Setup not found. Portable bundle: ${portable}`);
  } else {
    if (result.error) throw result.error;
    if (result.status !== 0) throw Error('Inno Setup failed to compile the Windows installer.');
    await requireFile(join(destination, `${installer}.exe`));
    console.info(destination);
  }
} catch (error) {
  console.error(error.code === 'EEXIST' ? 'Release directory already exists.' : error.message);
  process.exitCode = 1;
}
