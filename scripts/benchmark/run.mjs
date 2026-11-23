#!/usr/bin/env node
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { benchmarkProcess } from './managed-process.mjs';
import { runReplay } from './replay.mjs';
import { writeReports } from './reports.mjs';
import { runWorkloads } from './workloads.mjs';

const backends = ['nuxt', 'go', 'rust'];
const workloadNames = ['feed', 'profile', 'createPost', 'likePost', 'refresh', 'websocketBroadcast', 'aiWriting'];

function environmentValue(name, field) {
  if (typeof name !== 'string' || !/^[A-Za-z_][A-Za-z0-9_]*$/.test(name) || !process.env[name]) {
    throw new Error(`Configure the environment variable for ${field}.`);
  }
  return process.env[name];
}

function readOrigin(value, backend) {
  let url;
  try { url = new URL(value); } catch { /* Report the target name only. */ }
  if (!url || !['http:', 'https:'].includes(url.protocol) ||
      url.username || url.password || url.pathname !== '/' || url.search || url.hash) {
    throw new Error(`Configure an HTTP origin for the ${backend} target.`);
  }
  return url.origin;
}

function positiveInteger(value, field) {
  if (!Number.isSafeInteger(value) || value <= 0) throw new Error(`${field} must be a positive integer.`);
  return value;
}

function launchEnvironment(launch, backend) {
  const env = launch?.env ?? {};
  const envFrom = launch?.envFrom ?? {};
  if (typeof launch?.command !== 'string' || !launch.command ||
      !Array.isArray(launch.args) || launch.args.some(value => typeof value !== 'string') ||
      (launch.cwd !== undefined && typeof launch.cwd !== 'string') ||
      Object.values(env).some(value => typeof value !== 'string')) {
    throw new Error(`Configure the ${backend} launch command, arguments and environment.`);
  }
  return {
    command: launch.command,
    args: launch.args,
    cwd: resolve(launch.cwd ?? '.'),
    env: {
      ...env,
      ...Object.fromEntries(Object.entries(envFrom).map(([key, value]) => [key, environmentValue(value, `${backend} launch ${key}`)])),
    },
  };
}

async function readConfig(file, kind) {
  let config;
  try { config = JSON.parse(await readFile(file, 'utf8')); }
  catch { throw new Error('Could not read the benchmark configuration JSON.'); }
  const settings = {
    requests: positiveInteger(config?.benchmark?.requests ?? 20, 'requests'),
    concurrency: positiveInteger(config?.benchmark?.concurrency ?? 2, 'concurrency'),
    timeoutMs: positiveInteger(config?.benchmark?.timeoutMs ?? 8000, 'timeoutMs'),
    startupTimeoutMs: positiveInteger(config?.benchmark?.startupTimeoutMs ?? 60000, 'startupTimeoutMs'),
  };
  if (settings.concurrency > settings.requests) throw new Error('concurrency cannot exceed requests.');
  const targets = Object.fromEntries(backends.map(backend => {
    const item = config?.targets?.[backend];
    const target = {
      baseUrl: readOrigin(item?.baseUrl, backend),
      account: environmentValue(item?.accountEnv, `${backend} fixture account`),
      password: environmentValue(item?.passwordEnv, `${backend} fixture password`),
    };
    if (kind === 'parity') {
      target.oracle = Object.fromEntries(['user', 'password', 'connectString'].map(field =>
        [field, environmentValue(item.oracle?.[`${field}Env`], `${backend} Oracle ${field}`)]));
    } else {
      target.chatChannelId = positiveInteger(item.chatChannelId, `${backend} chatChannelId`);
      target.launch = launchEnvironment(item.launch, backend);
    }
    return [backend, target];
  }));
  if (new Set(Object.values(targets).map(target => target.baseUrl)).size !== backends.length) {
    throw new Error('Each target requires its own HTTP origin.');
  }
  if (kind === 'parity' && new Set(Object.values(targets).map(({ oracle }) =>
    JSON.stringify([oracle.user.toUpperCase(), oracle.connectString]))).size !== backends.length) {
    throw new Error('Each target requires a reader for its own cloned Oracle schema.');
  }
  return { targets, settings };
}

async function benchmark(targets, settings) {
  const results = {};
  for (const backend of backends) {
    results[backend] = await benchmarkProcess(targets[backend], settings, runWorkloads);
  }
  const passed = Object.values(results).every(row => !row.error && row.startupMs !== null && row.peakRssMiB !== null &&
    workloadNames.every(name => row.workloads[name]?.successful === settings.requests &&
      row.workloads[name].errors === 0 && (row.workloads[name].cleanupErrors ?? 0) === 0));
  return { passed, settings, targets: results };
}

async function main() {
  const [kind, ...rest] = process.argv.slice(2);
  const flags = new Map([[rest[0], rest[1]], [rest[2], rest[3]]]);
  if (!['parity', 'benchmark'].includes(kind) || rest.length !== 4 || !flags.get('--config') || !flags.get('--out')) {
    throw new Error('Usage: node scripts/benchmark/run.mjs <parity|benchmark> --config PATH --out DIR');
  }
  const { targets, settings } = await readConfig(flags.get('--config'), kind);
  const result = kind === 'parity' ? await runReplay(targets, settings) : await benchmark(targets, settings);
  await writeReports(resolve(flags.get('--out')), kind, result);
  console.log(`${kind}: ${result.passed ? 'passed' : 'differences or incomplete measurements'}.`);
  if (!result.passed) process.exitCode = 1;
}

try {
  await main();
} catch (error) {
  console.error(typeof error?.code === 'string' ? 'Unable to read or write a required file or launch a process.' : error.message);
  process.exitCode = 1;
}
