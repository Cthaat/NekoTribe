import { spawn } from 'node:child_process';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { basename, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseEnv } from 'node:util';

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const workspace = resolve(scriptDirectory, '../..');
const usage = 'Usage: node start-native.mjs <go|rust> [--env-file PATH]... [--binary PATH] [--check|--check-config|skills ...], or omit the backend in a native worktree or release directory';
const backends = {
  go: {port:30006, portKey:'GO_BACKEND_PORT', manifest:'go.mod', command:'go', args:['run','./cmd/server']},
  rust: {port:30003, portKey:'RUST_BACKEND_PORT', manifest:'Cargo.toml', command:'cargo', args:['run','--locked']},
};
const required = ['ACCESS_SECRET','REFRESH_SECRET','ORACLE_HOST','ORACLE_SERVICE_NAME','ORACLE_USER','ORACLE_PASSWORD'];

function options(argv) {
  const [backend, ...args] = argv;
  if (!Object.hasOwn(backends,backend)) throw Error(usage);
  const envFiles = [];
  let binaryPath;
  let check = false;
  let backendCheck = false;
  let skillArgs;
  for (let i = 0; i < args.length; i++) {
    const option = args[i];
    if (option === 'skills' && !check && !backendCheck) {
      skillArgs = args.slice(i + 1);
      break;
    }
    if ((option === '--check' || option === '--check-config') && !check && !backendCheck) {
      check = option === '--check';
      backendCheck = option === '--check-config';
      continue;
    }
    if (option !== '--env-file' && (option !== '--binary' || binaryPath)) throw Error(usage);
    const value = args[++i];
    if (!value || value.startsWith('--')) throw Error(usage);
    if (option === '--env-file') envFiles.push(resolve(value));
    else binaryPath = resolve(value);
  }
  return {backend, envFiles, binaryPath, check, backendCheck, skillArgs};
}

function requireFile(path, message) {
  try {
    if (statSync(path).isFile()) return;
  } catch {
    // Treat missing or unreadable files alike in the launcher output.
  }
  throw Error(message);
}

function releaseMetadata() {
  const path = resolve(scriptDirectory, 'native-package.json');
  requireFile(path, 'Release manifest not found. Select a backend for source mode.');
  let manifest;
  try {
    if (statSync(path).size > 8192) throw Error();
    manifest = JSON.parse(readFileSync(path, 'utf8'));
  } catch {
    throw Error('Invalid native release manifest.');
  }
  if (![1, 2, 3, 4].includes(manifest?.version) || !['go', 'rust'].includes(manifest.backend) ||
      !['windows', 'linux'].includes(manifest.os) || !['x64', 'arm64'].includes(manifest.arch)) {
    throw Error('Invalid native release manifest.');
  }
  const actualOS = process.platform === 'win32' ? 'windows' : process.platform;
  if (manifest.os !== actualOS || manifest.arch !== process.arch) {
    throw Error(`This release targets ${manifest.os}-${manifest.arch}. Use a package for ${actualOS}-${process.arch}.`);
  }
  const executable = `nekotribe-${manifest.backend}${manifest.os === 'windows' ? '.exe' : ''}`;
  const hasProbe = manifest.version === 2 || (manifest.version >= 3 && manifest.ffprobe !== undefined);
  const ffprobe = hasProbe ? `ffprobe${manifest.os === 'windows' ? '.exe' : ''}` : undefined;
  if (manifest.executable !== executable || manifest.ffprobe !== ffprobe) throw Error('Invalid native release manifest.');
  return {backend: manifest.backend, executable, ffprobe, offlineConfigCheck: manifest.offlineConfigCheck === true,
    skillMaintenance: manifest.skillMaintenance === true};
}

export function prepareNativeLaunch(argv, inherited = process.env, root = workspace) {
  const project = resolve(scriptDirectory, '..');
  const automatic = argv.length === 0 || argv[0] === 'skills' || argv[0].startsWith('--');
  const release = automatic && existsSync(resolve(scriptDirectory, 'native-package.json')) ? releaseMetadata() : null;
  const sourceBackends = automatic && !release && basename(scriptDirectory) === 'scripts'
    ? Object.keys(backends).filter(name => existsSync(resolve(project, backends[name].manifest)))
    : [];
  if (automatic && !release && sourceBackends.length !== 1) throw Error(usage);
  const localBackend = release?.backend ?? sourceBackends[0];
  const {backend, envFiles, binaryPath: explicitBinary, check, backendCheck, skillArgs} = options(automatic ? [localBackend, ...argv] : argv);
  if (release && explicitBinary) throw Error('Specify a backend to use --binary.');
  if (backendCheck && (explicitBinary || (release && !release.offlineConfigCheck))) {
    throw Error('Offline backend configuration checks require the source worktree or a release created with --build.');
  }
  if (skillArgs && (explicitBinary || (release && !release.skillMaintenance))) {
    throw Error('Skill maintenance requires the source worktree or a release with Skill maintenance support.');
  }
  const binaryPath = release ? resolve(scriptDirectory, release.executable) : explicitBinary;
  const target = backends[backend];
  const source = root === workspace && existsSync(resolve(project, target.manifest))
    ? project
    : resolve(root, backend);
  const cwd = binaryPath ? dirname(binaryPath) : source;
  if (binaryPath) requireFile(binaryPath, 'The backend binary is missing or unreadable.');
  else requireFile(resolve(cwd,target.manifest), 'The selected backend worktree is missing.');

  const env = Object.create(null);
  function merge(layer) {
    for (const [key,value] of Object.entries(layer)) {
      env[process.platform === 'win32' ? key.toUpperCase() : key] = value;
    }
  }
  const paths = envFiles.length || !automatic ? envFiles : [resolve(release ? scriptDirectory : source, `.env.${backend}`)];
  for (const path of paths) {
    try {
      merge(parseEnv(readFileSync(path,'utf8')));
    } catch (error) {
      if (automatic && !envFiles.length && error.code === 'ENOENT') continue;
      throw Error(envFiles.length ? 'Could not read an explicit environment file.' : 'Could not read the local backend environment file.');
    }
  }
  merge(inherited);
  const args = binaryPath ? [] : [...target.args];
  if (skillArgs) {
    if (!binaryPath && backend === 'rust') args.push('--');
    args.push('skills', ...skillArgs);
    return {backend, check:false, env, cwd, command:binaryPath ?? target.command, args};
  }
  if (release?.ffprobe && !env.FFPROBE_PATH?.trim()) {
    const path = resolve(scriptDirectory, release.ffprobe);
    requireFile(path, 'The packaged ffprobe executable is missing or unreadable.');
    env.FFPROBE_PATH = path;
  }
  if (backend === 'rust') env.RUST_BACKEND_MODE = 'native';
  const missing = required.filter(key => !(env[`NUXT_${key}`] ?? env[key])?.trim());
  if (missing.length) throw Error(`Missing native backend settings: ${missing.join(', ')}`);
  const port = env[target.portKey] || env.PORT || String(target.port);
  if (!/^[0-9]+$/.test(port) || Number(port) < 1 || Number(port) > 65535) {
    throw Error(`Invalid ${target.portKey} or PORT.`);
  }
  env[target.portKey] = String(Number(port));

  if (backendCheck) {
    if (!binaryPath && backend === 'rust') args.push('--');
    args.push('--check-config');
  }
  return {backend, port:Number(port), check, env, cwd,
    command:binaryPath ?? target.command, args};
}

function run(plan) {
  if (plan.check) {
    console.info(`${plan.backend} native configuration checked for port ${plan.port}.`);
    return;
  }
  const child = spawn(plan.command,plan.args,{cwd:plan.cwd,env:plan.env,stdio:'inherit',shell:false});
  const terminate = () => child.kill('SIGTERM');
  process.on('SIGTERM',terminate);
  child.once('close',(code, signal) => {
    process.off('SIGTERM',terminate);
    if (!process.exitCode) process.exitCode = code ?? (signal === 'SIGINT' ? 130 : 143);
  });
  child.once('error',() => {
    console.error('Could not start the backend. Check the toolchain or explicit binary.');
    process.exitCode = 1;
  });
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { run(prepareNativeLaunch(process.argv.slice(2))); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
