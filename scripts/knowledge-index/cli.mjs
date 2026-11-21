import { setTimeout as delay } from 'node:timers/promises';
import { profileFingerprint, readProfile } from './config.mjs';
import { activateIndex, bootstrapIndex, switchIndex, verifyIndex } from './bootstrap.mjs';
import { checkIndexReadiness, startIndexServer } from './server.mjs';
import { activeProfileFingerprint, prune, recover, rollbackTarget } from './lifecycle.mjs';
import { indexProgress } from './progress.mjs';
import { syncIndex } from './sync.mjs';
import { readWatchStatus, writeWatchStatus } from './watch-status.mjs';

const [mode,path,...extra] = process.argv.slice(2);
const activePath = process.env.AI_INDEX_ACTIVE_PROFILE;

function errorCode(error) {
  return /^[A-Z][A-Z_]{2,63}$/.test(error?.message) ? error.message : 'DEPENDENCY_OR_CONFIGURATION_ERROR';
}

async function withStopSignal(action) {
  const controller = new AbortController();
  const stop = () => controller.abort();
  process.on('SIGINT',stop);
  process.on('SIGTERM',stop);
  try {
    await action(controller.signal);
  } finally {
    process.off('SIGINT',stop);
    process.off('SIGTERM',stop);
  }
}

async function serve(signal) {
  const server = await startIndexServer(activePath);
  console.info('Knowledge index listening');
  await new Promise((resolve,reject) => {
    const close = () => server.close(error => error ? reject(error) : resolve());
    if (signal.aborted) close();
    else signal.addEventListener('abort',close,{once:true});
  });
}

async function watch(signal) {
  const seconds = Number(process.env.AI_INDEX_SYNC_SECONDS ?? 900);
  if (!Number.isInteger(seconds) || seconds < 60 || seconds > 86400) throw Error('INVALID_SYNC_INTERVAL');
  if (!activePath) throw Error('ACTIVE_PROFILE_REQUIRED');
  const previous = await readWatchStatus(activePath).catch(() => undefined);
  let lastSuccessAt = previous?.lastSuccessAt ?? null;
  let lastFinishedAt = previous?.lastFinishedAt ?? null;
  let lastOutcome = previous?.lastOutcome ?? null;
  let attemptedAt = Date.now();
  let retrySeconds = 60;
  const report = async (phase, nextAt = null) => {
    try {
      await writeWatchStatus(activePath,{phase,attemptedAt,nextAt,lastSuccessAt,lastFinishedAt,lastOutcome});
    } catch (error) {
      console.error(`Knowledge index watch status write failed: ${errorCode(error)}`);
    }
  };
  while (!signal.aborted) {
    attemptedAt = Date.now();
    await report('syncing');
    let synced = false;
    try {
      const result = await syncIndex(activePath,undefined,{signal,onProgress:indexProgress('watch')});
      synced = true;
      lastSuccessAt = lastFinishedAt = Date.now();
      lastOutcome = result.changed ? 'updated' : 'unchanged';
      console.info(JSON.stringify({mode,...result}));
    } catch (error) {
      lastFinishedAt = Date.now();
      if (signal.aborted && error === signal.reason) {
        lastOutcome = 'cancelled';
        break;
      }
      lastOutcome = 'failed';
      console.error(`Knowledge index sync failed: ${errorCode(error)}`);
    }
    if (synced && !signal.aborted && process.env.AI_INDEX_AUTO_PRUNE === '1') {
      await report('pruning');
      try {
        const result = await prune(activePath,true,{signal});
        if (result.removed.length || result.skipped.length) console.info(JSON.stringify({mode:'prune',...result}));
      } catch (error) {
        if (!signal.aborted || error !== signal.reason) console.error(`Knowledge index prune failed: ${errorCode(error)}`);
      }
    }
    if (signal.aborted) break;
    const waitSeconds = synced ? seconds : retrySeconds;
    retrySeconds = synced ? 60 : Math.min(seconds,retrySeconds*2);
    const nextAt = Date.now() + waitSeconds * 1000;
    await report('waiting',nextAt);
    try {
      await delay(Math.max(0,nextAt-Date.now()),undefined,{signal});
    } catch (error) {
      if (!signal.aborted) throw error;
    }
  }
  await report('stopped');
}

try {
  const validArgs = ['build','activate','bootstrap','switch','rollback'].includes(mode) ? !!path
    : mode === 'prune' ? path === undefined || path === '--apply'
    : mode === 'verify' ? path === undefined || !path.startsWith('--')
    : ['serve','health','check-sources','sync','watch','watch-status','recover'].includes(mode) && path === undefined;
  if (extra.length || !validArgs) {
    console.error('Usage: node cli.mjs serve | health | check-sources | bootstrap <profile.json> | switch <profile.json> | build <profile.json> | verify [profile.json] | activate <profile.json> | sync | watch | watch-status | rollback <collection> | recover | prune [--apply]');
    process.exitCode = 2;
  } else if (mode === 'serve') {
    await withStopSignal(serve);
  } else if (mode === 'health') {
    await checkIndexReadiness();
    console.info('Knowledge index ready');
  } else if (mode === 'check-sources') {
    await withStopSignal(async signal => {
      const {checkOracleSources} = await import('./oracle.mjs');
      const result = await checkOracleSources({signal});
      console.info(JSON.stringify({mode,...result}));
      if (!result.ready) process.exitCode = 1;
    });
  } else if (mode === 'verify') {
    await withStopSignal(async signal => {
      const profilePath = path ?? activePath;
      if (!profilePath) throw Error('ACTIVE_PROFILE_REQUIRED');
      const profile = await readProfile(profilePath);
      const result = await verifyIndex(profile,{signal,onProgress:indexProgress(mode)});
      if (path === undefined && await activeProfileFingerprint(activePath) !== profileFingerprint(profile)) {
        throw Error('ACTIVE_PROFILE_CHANGED');
      }
      signal.throwIfAborted();
      console.info(JSON.stringify({mode,...result,verified:true}));
    });
  } else if (mode === 'build') {
    await withStopSignal(async signal => {
      const {buildIndex} = await import('./build.mjs');
      console.info(JSON.stringify({mode,...await buildIndex(await readProfile(path),undefined,{signal,onProgress:indexProgress(mode)})}));
    });
  } else if (mode === 'bootstrap') {
    await withStopSignal(async signal => {
      console.info(JSON.stringify({mode,...await bootstrapIndex(activePath,path,{signal,onProgress:indexProgress(mode)})}));
    });
  } else if (mode === 'activate') {
    await withStopSignal(async signal => {
      console.info(JSON.stringify({mode,...await activateIndex(activePath,await readProfile(path),{signal,onProgress:indexProgress(mode)})}));
    });
  } else if (mode === 'switch') {
    await withStopSignal(async signal => {
      console.info(JSON.stringify({mode,...await switchIndex(activePath,await readProfile(path),{signal,onProgress:indexProgress(mode)})}));
    });
  } else if (mode === 'rollback') {
    await withStopSignal(async signal => {
      const {profile,expected} = await rollbackTarget(activePath,path);
      console.info(JSON.stringify({mode,...await activateIndex(activePath,profile,{expected,signal,onProgress:indexProgress(mode)})}));
    });
  } else if (mode === 'prune') {
    const result = await prune(activePath,path === '--apply');
    console.info(JSON.stringify({mode,...result}));
    if (result.skipped.length) process.exitCode = 1;
  } else if (mode === 'recover') {
    console.info(JSON.stringify({mode,...await recover(activePath)}));
  } else if (mode === 'sync') {
    await withStopSignal(async signal => {
      console.info(JSON.stringify({mode,...await syncIndex(activePath,undefined,{signal,onProgress:indexProgress(mode)})}));
    });
  } else if (mode === 'watch-status') {
    const state = await readWatchStatus(activePath);
    console.info(JSON.stringify({mode,...(state ?? {version:1,phase:'unknown'})}));
  } else {
    await withStopSignal(watch);
  }
} catch (error) {
  console.error(`Knowledge index ${mode} failed: ${errorCode(error)}`);
  process.exitCode = 1;
}
