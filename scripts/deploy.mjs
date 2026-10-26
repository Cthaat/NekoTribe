import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { parseEnv } from 'node:util';
import { fileURLToPath } from 'node:url';
import { resolveRuntimeEnvironment } from './runtime-env.mjs';

const projectRoot = fileURLToPath(new URL('..', import.meta.url));
const files = {
  source: 'docker-compose.local.yml',
  image: 'docker-compose.yml',
  external: 'docker-compose.external.yml',
  dependencies: 'docker-compose.local.yml'
};
const actions = new Set(['plan', 'up', 'stop', 'status', 'logs', 'build', 'init-db', 'migrate-db']);

// Planning reads configuration only; execution requires an explicit action.
export function planDeployment({ root = projectRoot, action = 'plan', mode = 'source', envFile = '.env', project, env = process.env } = {}) {
  if (!Object.hasOwn(files, mode) || !actions.has(action)) throw new Error('Use plan/up/stop/status/logs/build/init-db/migrate-db and source/image/external/dependencies.');
  const environmentPath = resolve(root, envFile);
  let parsed;
  try { parsed = parseEnv(readFileSync(environmentPath, 'utf8')); }
  catch { throw new Error('Environment file is missing or unreadable. Copy .env.example and configure it first.'); }
  const values = resolveRuntimeEnvironment({ ...parsed, ...env }, 'start');
  const projectName = project ?? values.COMPOSE_PROJECT_NAME ?? 'nekotribe';
  if (!/^[a-z0-9][a-z0-9_-]*$/.test(projectName)) throw new Error('Compose project must use lowercase letters, digits, underscores or hyphens.');
  if (action === 'build' && ['image', 'dependencies'].includes(mode)) throw new Error('This mode has no application source build; use source or external.');
  if (action === 'init-db' && mode === 'external') throw new Error('External dependencies are managed externally; no database initialization is provided.');
  if (mode === 'external' && ['up', 'build', 'migrate-db'].includes(action)) {
    const runtime = resolveRuntimeEnvironment(values, 'start');
    const oracleHost = runtime.NUXT_ORACLE_HOST?.trim();
    if (!oracleHost || ['localhost', '127.0.0.1', '::1'].includes(oracleHost.toLowerCase())) {
      throw new Error('External Oracle must use an address reachable from the container, such as host.docker.internal or a database hostname.');
    }
    const redisUrl = runtime.NUXT_REDIS_URL?.trim();
    let redisHost = runtime.NUXT_REDIS_HOST?.trim();
    if (redisUrl) {
      try { redisHost = new URL(redisUrl).hostname; }
      catch { throw new Error('Redis URL is invalid.'); }
    }
    if (!redisHost || ['localhost', '127.0.0.1', '::1', '[::1]'].includes(redisHost.toLowerCase())) {
      throw new Error('External Redis must use an address reachable from the container.');
    }
  }
  const base = ['compose', '--project-directory', root, '--env-file', environmentPath, '-p', projectName, '-f', resolve(root, files[mode])];
  const services = mode === 'dependencies' ? ['redis', 'oracle19c'] : [];
  const commands = {
    plan: [],
    up: [...base, 'up', '-d', ...(mode === 'source' || mode === 'external' ? ['--build'] : []), ...services],
    stop: [...base, 'stop', ...services],
    status: [...base, 'ps', ...services],
    logs: [...base, 'logs', '--tail', '100', '-f', ...services],
    build: [...base, 'build', 'app'],
    'init-db': [...base, 'run', '--rm', '-e', 'DB_INIT_ALLOW_EMPTY=true', 'db-init'],
    'migrate-db': [...base, 'run', '--rm', '--no-deps', ...(mode !== 'image' ? ['--build'] : []), '--entrypoint', 'node', 'app', 'scripts/migrate-db.mjs', '--apply']
  };
  return { mode, action, project: projectName, envFile: environmentPath, composeFile: files[mode], args: commands[action], ...(action === 'plan' ? { preview: ['docker', ...commands.up] } : {}), childEnv: { ...values, ENV_FILE: environmentPath } };
}

export function deploy(options = {}, run = spawnSync) {
  const plan = planDeployment(options);
  if (plan.action !== 'plan') {
    const result = run('docker', plan.args, { cwd: options.root ?? projectRoot, env: plan.childEnv, stdio: 'inherit', windowsHide: true });
    if (result.error || result.status !== 0) throw new Error('Deployment command failed. Check Docker, configuration and dependencies.');
  }
  // Never return or print private environment values.
  const { childEnv, ...publicPlan } = plan;
  return publicPlan;
}

export function parseDeploymentArgs(args) {
  const [action = 'plan', ...rest] = args;
  const options = { action };
  const names = { '--mode': 'mode', '--env': 'envFile', '--project': 'project' };
  const seen = new Set();
  for (let index = 0; index < rest.length; index += 2) {
    const key = rest[index];
    if (!Object.hasOwn(names, key) || !rest[index + 1] || seen.has(key)) throw new Error('Expected --mode, --env or --project followed by a value, once each.');
    seen.add(key);
    options[names[key]] = rest[index + 1];
  }
  return options;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { console.log(JSON.stringify(deploy(parseDeploymentArgs(process.argv.slice(2))), null, 2)); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
