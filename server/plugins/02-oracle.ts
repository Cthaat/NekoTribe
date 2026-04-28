import {
  defineNitroPlugin,
  useRuntimeConfig
} from '#imports';
import oracledb from 'oracledb';
import {
  logError,
  logInfo,
  serializeLogError
} from '~/server/utils/logging';

// 1. 单例容器 (Singleton Container) - 无需改动
export let pool: oracledb.Pool | null = null;

// 2. 初始化函数 - 无需改动
async function initOraclePool() {
  if (!pool) {
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
    } catch (e) {
      logError('oracle', {
        event: 'pool:create:error',
        error: serializeLogError(e)
      });
      throw e; // 抛出错误很重要
    }
  }
  return pool;
}

// 3. 获取连接的函数 - 无需改动
async function getOracleConnection() {
  const pool = await initOraclePool();
  return await pool.getConnection();
}

export default defineNitroPlugin(nitroApp => {
  // 4. 【关键改动】删除插件底部的预初始化调用！
  //    不再有 initOraclePool().catch(...) 这一行。

  // 5. 【关键改动】使用 Object.defineProperty 进行惰性注入
  nitroApp.hooks.hook('request', event => {
    // 我们不再直接赋值，而是定义一个 getter
    Object.defineProperty(
      event.context,
      'getOracleConnection',
      {
        // 当您的代码中第一次访问 event.context.getOracleConnection 时，
        // 这个 get 函数才会被执行，它会返回我们真正的 getOracleConnection 函数。
        get() {
          return getOracleConnection;
        },

        // 允许此属性在热更新（HMR）时被重新配置。
        configurable: true
      }
    );
  });

  nitroApp.hooks.hook('close', async () => {
    if (!pool) {
      return;
    }

    logInfo('oracle', {
      event: 'pool:close:start'
    });
    await pool.close();
    logInfo('oracle', {
      event: 'pool:close:success'
    });
    pool = null;
  });
});
