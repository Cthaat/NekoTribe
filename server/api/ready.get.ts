import { getOracleConnection } from '../utils/oracle';
import { getRedisClient } from '../utils/redis';

const PROBE_TIMEOUT_MS = 2000;
let activeProbe: Promise<boolean> | undefined;

async function checkOracle(): Promise<boolean> {
  const connection = await getOracleConnection();
  try {
    await connection.ping();
    return true;
  } finally {
    await connection.close();
  }
}

async function checkRedis(): Promise<boolean> {
  const redis = getRedisClient();
  return redis?.status === 'ready' && await redis.ping() === 'PONG';
}

function readyWithinDeadline(): Promise<boolean> {
  if (activeProbe) return activeProbe;

  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<boolean>(resolve => {
    timer = setTimeout(() => resolve(false), PROBE_TIMEOUT_MS);
  });
  const checks = Promise.allSettled([checkOracle(), checkRedis()])
    .then(results => results.every(result => result.status === 'fulfilled' && result.value))
    .finally(() => {
      clearTimeout(timer);
      activeProbe = undefined;
    });
  activeProbe = Promise.race([checks, deadline]);
  return activeProbe;
}

export default defineEventHandler(async event => {
  setResponseHeader(event, 'Cache-Control', 'no-store');
  const ready = await readyWithinDeadline();
  if (!ready) setResponseStatus(event, 503);
  return { status: ready ? 'ready' : 'unavailable' };
});
