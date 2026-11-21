import { randomUUID } from 'node:crypto';
import { lstat, open, readFile, realpath, rename, rm } from 'node:fs/promises';
import { isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const usage = 'Usage: node configure-web.mjs WEB_DIR --check | WEB_DIR --api HTTP_BASE [--realtime WS_BASE] [--media HTTP_BASE] [--share-site HTTP_BASE]';
const http = ['http:', 'https:'];
const websocket = ['ws:', 'wss:'];

function baseUrl(value, protocols, label) {
  let url;
  try { url = new URL(value); } catch { throw Error(`Invalid ${label} base URL.`); }
  if (typeof value !== 'string' || /[\s\\?#]/u.test(value) || !/^[a-z]+:\/\/[^/]+/i.test(value) ||
      /^\w+:\/\/[^/]*@/i.test(value) || url.username || url.password ||
      !protocols.includes(url.protocol) || !url.hostname || url.port === '0') {
    throw Error(`Invalid ${label} base URL.`);
  }
  return url.href.replace(/\/+$/, '');
}

async function regularAsset(root, ...segments) {
  const path = join(root, ...segments);
  const actual = await realpath(path);
  const within = relative(root, actual);
  if (!within || isAbsolute(within) || within === '..' || within.startsWith(`..${sep}`) ||
      !(await lstat(path)).isFile()) throw Error('Invalid Flutter Web asset.');
  return actual;
}

function addresses(config) {
  const api = baseUrl(config.defaults.apiBaseUrl, http, 'API');
  const realtime = config.defaults.wsBaseUrl
    ? baseUrl(config.defaults.wsBaseUrl, websocket, 'realtime')
    : api.replace(/^http/, 'ws');
  const media = config.defaults.storageBaseUrl
    ? baseUrl(config.defaults.storageBaseUrl, http, 'media')
    : api;
  const shareSite = config.groupPostShareBaseUrl
    ? baseUrl(config.groupPostShareBaseUrl, http, 'share site')
    : null;
  return {api, realtime, media, shareSite};
}

async function readConfig(path) {
  if ((await lstat(path)).size > 1024 * 1024) throw Error('Invalid Flutter Web configuration.');
  let config;
  try { config = JSON.parse(await readFile(path, 'utf8')); }
  catch { throw Error('Invalid Flutter Web configuration.'); }
  if (!config?.defaults || typeof config.defaults !== 'object' || Array.isArray(config.defaults) ||
      !Array.isArray(config.presets)) throw Error('Invalid Flutter Web configuration.');
  return config;
}

export async function configureWeb(directory, settings = null) {
  const root = await realpath(directory);
  await Promise.all([regularAsset(root, 'index.html'), regularAsset(root, 'flutter_bootstrap.js')]);
  const path = await regularAsset(root, 'assets', 'assets', 'config', 'app_config.json');
  if (!settings) return addresses(await readConfig(path));

  const lockPath = `${path}.lock`;
  const lock = await open(lockPath, 'wx');
  const temporary = `${path}.${randomUUID()}.tmp`;
  try {
    const config = await readConfig(path);
    config.defaults.apiBaseUrl = baseUrl(settings.api, http, 'API');
    config.defaults.presetId = 'custom';
    if (settings.realtime) config.defaults.wsBaseUrl = baseUrl(settings.realtime, websocket, 'realtime');
    else delete config.defaults.wsBaseUrl;
    if (settings.media) config.defaults.storageBaseUrl = baseUrl(settings.media, http, 'media');
    else delete config.defaults.storageBaseUrl;
    if (settings.shareSite !== undefined) config.groupPostShareBaseUrl = baseUrl(settings.shareSite, http, 'share site');
    const result = addresses(config);
    const mode = (await lstat(path)).mode & 0o777;
    const file = await open(temporary, 'wx', mode);
    try {
      await file.writeFile(`${JSON.stringify(config, null, 2)}\n`);
      await file.sync();
    } finally {
      await file.close();
    }
    await rename(temporary, path);
    return result;
  } finally {
    try { await rm(temporary, { force: true }); }
    finally {
      await lock.close();
      await rm(lockPath);
    }
  }
}

function parseArgs(argv) {
  const [directory, ...rest] = argv;
  if (!directory || directory.startsWith('--')) throw Error(usage);
  if (rest.length === 1 && rest[0] === '--check') return {directory, settings: null};
  const flags = new Map([['--api', 'api'], ['--realtime', 'realtime'], ['--media', 'media'], ['--share-site', 'shareSite']]);
  const settings = {};
  for (let i = 0; i < rest.length; i += 2) {
    const key = flags.get(rest[i]);
    const value = rest[i + 1];
    if (!key || Object.hasOwn(settings, key) || !value || value.startsWith('--')) throw Error(usage);
    settings[key] = value;
  }
  if (!settings.api) throw Error(usage);
  return {directory, settings};
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const {directory, settings} = parseArgs(process.argv.slice(2));
    console.info(JSON.stringify(await configureWeb(directory, settings)));
  } catch (error) {
    console.error(error.code ? (error.code === 'EEXIST' ? 'Flutter Web configuration is being updated.' :
      'Could not access the Flutter Web assets.') : error.message);
    process.exitCode = 1;
  }
}
