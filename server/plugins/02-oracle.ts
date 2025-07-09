import { defineNitroPlugin } from '#imports';
import oracledb from 'oracledb';

let pool: oracledb.Pool | null = null;

async function initOraclePool() {
  if (!pool) {
    const runtimeConfig = useRuntimeConfig();
    pool = await oracledb.createPool({
      user: runtimeConfig.oracleUser,
      password: runtimeConfig.oraclePassword,
      connectString: `${runtimeConfig.oracleHost}:${runtimeConfig.oraclePort}/${runtimeConfig.oracleServiceName}`,
      poolMin: Number(runtimeConfig.oraclePoolMin) || 2,
      poolMax: Number(runtimeConfig.oraclePoolMax) || 10,
      poolIncrement: Number(runtimeConfig.oraclePoolIncrement) || 1,
      poolTimeout: 300,
      queueMax: 0,
      queueTimeout: 60000
    });
    console.log('Oracle 连接池已创建');
  }
  return pool;
}

async function getOracleConnection() {
  const pool = await initOraclePool();
  return await pool.getConnection();
}

export default defineNitroPlugin(nitroApp => {
  // 可以在每个请求里注入 oraclePool 和 getOracleConnection 方法
  nitroApp.hooks.hook('request', event => {
    event.context.oraclePool = pool;
    event.context.getOracleConnection = getOracleConnection;
  });
  // 启动时可预初始化（可选）
  initOraclePool().catch(e => {
    console.error('Oracle 连接池初始化失败:', e);
  });
});
