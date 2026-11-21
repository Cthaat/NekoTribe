import { spawnSync } from 'node:child_process';
import { constants } from 'node:fs';
import { copyFile, lstat, mkdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

const usage = 'Usage: node scripts/package-android.mjs --version VERSION --out NEW_RELEASE_DIR';
const source = fileURLToPath(new URL('../build/app/outputs/flutter-apk/app-release.apk', import.meta.url));

// Python's ZIP reader verifies the directory, member headers, and CRCs for both stored and
// compressed entries. Signing is verified independently by apksigner in the workflow.
const checkApk = `
import sys
import zipfile

try:
    with zipfile.ZipFile(sys.argv[1]) as apk:
        for name in ('AndroidManifest.xml', 'classes.dex'):
            if apk.getinfo(name).file_size == 0:
                raise ValueError('empty ' + name)
        damaged = apk.testzip()
        if damaged is not None:
            raise ValueError('damaged ZIP member: ' + damaged)
except (KeyError, OSError, ValueError, zipfile.BadZipFile) as error:
    sys.exit('Invalid APK: ' + str(error))
`;

try {
  const { values } = parseArgs({ options: { version: { type: 'string' }, out: { type: 'string' } } });
  const { version, out } = values;
  if (!version || !/^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(version) || !out) throw Error(usage);

  const apk = await lstat(source).catch(error => {
    if (error.code === 'ENOENT') throw Error('Build the Android release APK before packaging.');
    throw error;
  });
  if (!apk.isFile() || !apk.size) throw Error('The Android release APK must be a nonempty file.');

  const result = spawnSync('python', ['-c', checkApk, source], { stdio: 'inherit' });
  if (result.error?.code === 'ENOENT') throw Error('Python 3 is required on PATH to validate the APK.');
  if (result.error) throw result.error;
  if (result.status !== 0) throw Error('The APK failed ZIP validation.');

  const destination = resolve(out);
  await mkdir(destination);
  const packagePath = resolve(destination, `NekoTribe-${version}-android.apk`);
  await copyFile(source, packagePath, constants.COPYFILE_EXCL);
  console.info(packagePath);
} catch (error) {
  console.error(error.code === 'EEXIST' ? 'Release directory already exists.' : error.message);
  process.exitCode = 1;
}
