import { execFile, spawn } from 'node:child_process';
import { once } from 'node:events';
import { readFile } from 'node:fs/promises';
import { setTimeout as delay } from 'node:timers/promises';
import { promisify } from 'node:util';
import { requestJson } from './http.mjs';

const exec = promisify(execFile);

async function readRss(pid) {
  if (process.platform === 'linux') {
    const status = await readFile(`/proc/${pid}/status`, 'utf8');
    const rss = /^VmRSS:\s+(\d+) kB$/m.exec(status);
    return rss ? Number(rss[1]) / 1024 : null;
  }
  if (process.platform === 'win32') {
    const { stdout } = await exec('powershell.exe', [
      '-NoProfile', '-NonInteractive', '-Command',
      `(Get-Process -Id ${pid} -ErrorAction Stop).WorkingSet64`,
    ], { windowsHide: true, timeout: 2000, maxBuffer: 4096 });
    const bytes = Number(stdout.trim());
    return bytes > 0 ? bytes / (1024 ** 2) : null;
  }
  return null;
}

async function closeChild(child) {
  if (child.exitCode !== null || child.signalCode !== null || !child.pid) return;
  const exited = once(child, 'exit').then(() => true, () => true);
  const timeout = new AbortController();
  child.kill();
  try {
    if (await Promise.race([exited, delay(5000, false, { signal: timeout.signal })])) return;
    child.kill('SIGKILL');
    await Promise.race([exited, delay(2000)]);
  } finally {
    timeout.abort();
  }
}

export async function benchmarkProcess(target, settings, run) {
  const { launch, baseUrl } = target;
  let preexisting = false;
  try {
    const result = await fetch(new URL('/api/ready', baseUrl), {
      redirect: 'manual',
      signal: AbortSignal.timeout(1000),
    });
    preexisting = true;
    await result.body?.cancel();
  } catch { /* An unused address does not accept HTTP yet. */ }
  if (preexisting) return { startupMs: null, peakRssMiB: null, workloads: {}, error: 'Target URL already has a responder.' };

  const started = performance.now();
  const child = spawn(launch.command, launch.args, {
    cwd: launch.cwd,
    env: { ...process.env, ...launch.env },
    stdio: 'ignore',
    windowsHide: true,
  });
  let failed = false;
  child.on('error', () => { failed = true; });
  let startupMs = null;
  let peakRssMiB = null;
  let workloads = {};
  let error;
  let reading;
  const sample = () => {
    if (!reading && child.pid) {
      reading = readRss(child.pid).then(value => {
        if (value !== null && Number.isFinite(value)) peakRssMiB = Math.max(peakRssMiB ?? 0, value);
      }).catch(() => {}).finally(() => { reading = undefined; });
    }
    return reading;
  };
  const timer = setInterval(sample, 1000);
  try {
    while (!failed && child.exitCode === null && child.signalCode === null &&
           performance.now() - started < settings.startupTimeoutMs) {
      const status = await requestJson(target, { path: '/api/ready', timeoutMs: Math.min(settings.timeoutMs, 1000) })
        .then(response => response.status, () => null);
      if (!failed && child.exitCode === null && child.signalCode === null && status === 200) {
        startupMs = performance.now() - started;
        break;
      }
      await delay(150);
    }
    if (startupMs === null) {
      error = failed || child.exitCode !== null || child.signalCode !== null
        ? 'Backend exited during startup.' : 'Backend did not become ready before the startup timeout.';
    } else {
      void sample();
      workloads = await run(target, settings);
      await sample();
      if (peakRssMiB === null) error = 'Resident memory could not be measured on this host.';
    }
  } catch {
    error = 'Backend workload could not be completed.';
  } finally {
    clearInterval(timer);
    await reading;
    await closeChild(child);
  }
  return {
    startupMs: startupMs === null ? null : Number(startupMs.toFixed(3)),
    peakRssMiB: peakRssMiB === null ? null : Number(peakRssMiB.toFixed(3)),
    workloads,
    ...(error ? { error } : {}),
  };
}
