import {
  useRuntimeConfig
} from '#imports';
import oracledb from 'oracledb';
import {
  logError,
  logInfo
} from '~/server/utils/logging';
import { clearOracleQueryCacheSource } from '~/server/utils/oracle-query-cache';

let pool: oracledb.Pool | null = null;

export async function initOraclePool(): Promise<oracledb.Pool> {
  if (pool) return pool;

  const runtimeConfig = useRuntimeConfig();
  const poolMin = Number(runtimeConfig.oraclePoolMin) || 2;
  const poolMax = Number(runtimeConfig.oraclePoolMax) || 10;
  const poolIncrement =
    Number(runtimeConfig.oraclePoolIncrement) || 1;

  logInfo('oracle', {
    event: 'pool:create:start',
    host: runtimeConfig.oracleHost,
    port: runtimeConfig.oraclePort,
    serviceName: runtimeConfig.oracleServiceName,
    poolMin,
    poolMax,
    poolIncrement
  });

  try {
    pool = await oracledb.createPool({
      user: runtimeConfig.oracleUser,
      password: runtimeConfig.oraclePassword,
      connectString: `${runtimeConfig.oracleHost}:${runtimeConfig.oraclePort}/${runtimeConfig.oracleServiceName}`,
      poolMin,
      poolMax,
      poolIncrement,
      poolTimeout: 300,
      queueMax: 100,
      queueTimeout: 60000
    });
    logInfo('oracle', {
      event: 'pool:create:success'
    });
    return pool;
  } catch (error) {
    let code: unknown;
    try { code = (error as { code?: unknown } | null)?.code; }
    catch { code = undefined; }
    logError('oracle', {
      event: 'pool:create:error',
      category: 'oracle_pool_initialization_failed',
      code: typeof code === 'string' && /^(?:ORA-\d{5}|NJS-\d{3,5}|DPI-\d{4})$/.test(code)
        ? code
        : 'unknown'
    });
    throw error;
  }
}

export async function getOracleConnection(): Promise<oracledb.Connection> {
  const activePool = await initOraclePool();
  return clearOracleQueryCacheSource(
    await activePool.getConnection()
  );
}

export async function closeOraclePool(): Promise<void> {
  if (!pool) return;

  logInfo('oracle', {
    event: 'pool:close:start'
  });
  await pool.close();
  logInfo('oracle', {
    event: 'pool:close:success'
  });
  pool = null;
}
