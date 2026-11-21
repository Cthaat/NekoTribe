import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { cp, lstat, mkdir, mkdtemp, realpath, rmdir, stat, unlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, delimiter, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

const usage = 'Usage: node scripts/package-windows.mjs --version VERSION --out NEW_RELEASE_DIR [--require-installer]';
const project = fileURLToPath(new URL('../', import.meta.url));
const chineseMessagesUrl = 'https://raw.githubusercontent.com/jrsoftware/issrc/6ef32198ef1f7b7b375cd4b6b90896c2a58eb4c2/Files/Languages/ChineseSimplified.isl';
const chineseMessagesSha256 = 'e0b0b350e2245f3c5e65586dfe43d574f6e7f06f2261149aba284954b3fc9a8d';
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
  for (const directory of (process.env.PATH ?? '').split(delimiter).filter(Boolean)) {
    const compiler = resolve(directory, 'ISCC.exe');
    if ((await stat(compiler, { throwIfNoEntry: false }))?.isFile()) return compiler;
  }
  return null;
}

async function compileInstaller(compiler, args) {
  const bundledLanguage = join(dirname(compiler), 'Languages', 'ChineseSimplified.isl');
  if ((await stat(bundledLanguage, { throwIfNoEntry: false }))?.isFile()) {
    return spawnSync(compiler, args, { stdio: 'inherit' });
  }

  const response = await fetch(chineseMessagesUrl, { signal: AbortSignal.timeout(30000) });
  if (!response.ok) throw Error(`Could not download Inno Setup's Simplified Chinese translation: HTTP ${response.status}.`);
  const messages = Buffer.from(await response.arrayBuffer());
  if (createHash('sha256').update(messages).digest('hex') !== chineseMessagesSha256) {
    throw Error('Inno Setup translation checksum mismatch.');
  }
  const temporary = await mkdtemp(join(tmpdir(), 'nekotribe-inno-'));
  const languageFile = join(temporary, 'ChineseSimplified.isl');
  try {
    // Explicitly mark UTF-8 so Inno Setup does not read the text as a legacy code page.
    await writeFile(languageFile, Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), messages]));
    return spawnSync(compiler, [`/DChineseMessagesFile=${languageFile}`, ...args], { stdio: 'inherit' });
  } finally {
    await unlink(languageFile).catch(error => {
      if (error.code !== 'ENOENT') throw error;
    });
    await rmdir(temporary);
  }
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
  const compiler = await findCompiler();
  if (!compiler) {
    if (values['require-installer']) throw Error('Inno Setup ISCC.exe is required for this package.');
    console.info(`Inno Setup not found. Portable bundle: ${portable}`);
  } else {
    await requireFile(compiler);
    const result = await compileInstaller(compiler, [
      `/DMyAppVersion=${version}`,
      `/DSourceDir=${portable}`,
      `/DOutputBaseFilename=${installer}`,
      ...(binaryVersion ? [`/DBinaryVersion=${binaryVersion}`] : []),
      `/O${destination}`,
      join(project, 'packaging/windows/nekotribe.iss'),
    ]);
    if (result.error) throw result.error;
    if (result.status !== 0) throw Error('Inno Setup failed to compile the Windows installer.');
    await requireFile(join(destination, `${installer}.exe`));
    console.info(destination);
  }
} catch (error) {
  console.error(error.code === 'EEXIST' ? 'Release directory already exists.' : error.message);
  process.exitCode = 1;
}
