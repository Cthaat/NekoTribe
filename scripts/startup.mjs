import { spawnSync } from 'node:child_process';
import { copyFileSync, constants } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export function startApplication({ root = resolve(dirname(fileURLToPath(import.meta.url)), '..'), mode, args = [], run = spawnSync } = {}) {
  if (!['dev', 'start'].includes(mode)) throw new Error('Expected dev or start.');
  const allowed = mode === 'dev' ? '--dependencies' : '--compose';
  if (args.some(arg => arg !== allowed)) throw new Error(`Only ${allowed} is supported; use yarn directly for application options.`);
  try { copyFileSync(resolve(root, '.env.example'), resolve(root, '.env'), constants.COPYFILE_EXCL); }
  catch (error) { if (error.code !== 'EEXIST') throw error; }
  function checked(command, commandArgs) {
    // Only fixed, internally defined Yarn arguments enter cmd.exe on Windows.
    const windowsYarn = run === spawnSync && process.platform === 'win32' && command === 'yarn';
    const result = run(windowsYarn ? 'cmd.exe' : command, windowsYarn ? ['/d', '/s', '/c', `yarn ${commandArgs.join(' ')}`] : commandArgs, { cwd: root, stdio: 'inherit', windowsHide: true });
    if (result.error || result.status !== 0) throw new Error(`${command} failed; startup stopped.`);
  }
  if (mode === 'dev') {
    if (args.includes('--dependencies')) checked('docker', ['compose', 'up', '-d', 'redis', 'oracle19c']);
    checked('yarn', ['install', '--frozen-lockfile']);
    checked('yarn', ['dev']);
  } else if (args.includes('--compose')) {
    checked('docker', ['compose', 'up', '-d', '--build']);
    checked('docker', ['compose', 'ps']);
  } else checked('yarn', ['start']);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { startApplication({ mode: process.argv[2], args: process.argv.slice(3) }); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
