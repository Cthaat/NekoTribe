import {
  useRuntimeConfig
} from '#imports';
import oracledb from 'oracledb';
import {
  logError,
  logInfo,
  serializeLogError
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
    logError('oracle', {
      event: 'pool:create:error',
      error: serializeLogError(error)
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
