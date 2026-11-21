import { readFile } from 'node:fs/promises';
import { writeJson } from './lifecycle.mjs';

const phases = new Set(['syncing', 'pruning', 'waiting', 'stopped']);
const outcomes = new Set(['updated', 'unchanged', 'failed', 'cancelled']);
const timestamp = value => Number.isSafeInteger(value) && value > 0;
const optionalTimestamp = value => value === null || timestamp(value);

function statusPath(activePath) {
  if (!activePath) throw Error('ACTIVE_PROFILE_REQUIRED');
  return `${activePath}.sync-status.json`;
}

export async function readWatchStatus(activePath) {
  const path = statusPath(activePath);
  let bytes;
  try {
    bytes = await readFile(path);
  } catch (error) {
    if (error?.code === 'ENOENT') return undefined;
    throw error;
  }
  try {
    if (bytes.length > 2048) throw Error();
    const state = JSON.parse(new TextDecoder('utf-8', {fatal:true}).decode(bytes));
    const {version, phase, updatedAt, attemptedAt, nextAt, lastSuccessAt, lastFinishedAt, lastOutcome} = state;
    if (version !== 1 || !phases.has(phase) || !timestamp(updatedAt) || !timestamp(attemptedAt) ||
        !optionalTimestamp(nextAt) || !optionalTimestamp(lastSuccessAt) || !optionalTimestamp(lastFinishedAt) ||
        (lastFinishedAt === null) !== (lastOutcome === null) ||
        (phase === 'waiting') !== (nextAt !== null) || (lastOutcome !== null && !outcomes.has(lastOutcome))) {
      throw Error();
    }
    return {version, phase, updatedAt, attemptedAt, nextAt, lastSuccessAt, lastFinishedAt, lastOutcome};
  } catch {
    throw Error('SYNC_STATUS_INVALID');
  }
}

export async function writeWatchStatus(activePath, state) {
  await writeJson(statusPath(activePath), {version:1, ...state, updatedAt:Date.now()});
}
