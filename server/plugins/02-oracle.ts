import {
  defineNitroPlugin,
  useRuntimeConfig
} from '#imports';
import oracledb from 'oracledb';

// 1. 单例容器 (Singleton Container) - 无需改动
export let pool: oracledb.Pool | null = null;

// 2. 初始化函数 - 无需改动
async function initOraclePool() {
  if (!pool) {
    console.log('Oracle 连接池实例不存在，正在创建...');
    const runtimeConfig = useRuntimeConfig();
    try {
      pool = await oracledb.createPool({
        user: runtimeConfig.oracleUser,
        password: runtimeConfig.oraclePassword,
        connectString: `${runtimeConfig.oracleHost}:${runtimeConfig.oraclePort}/${runtimeConfig.oracleServiceName}`,
        poolMin: Number(runtimeConfig.oraclePoolMin) || 2,
        poolMax: Number(runtimeConfig.oraclePoolMax) || 10,
        poolIncrement:
          Number(runtimeConfig.oraclePoolIncrement) || 1,
        poolTimeout: 300,
        queueMax: 100,
        queueTimeout: 60000
      });
      console.log('Oracle 连接池已成功创建');
    } catch (e) {
      console.error('Oracle 连接池初始化失败:', e);
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

    nitroApp.hooks.hook('close', async () => {
      // 检查连接池是否在应用的生命周期中被创建了
      if (pool) {
        console.log(
          'Nitro 正在关闭，开始清理 Oracle 连接池...'
        );
        // 如果创建了，就优雅地关闭它
        await pool.close();
        console.log('Oracle 连接池已成功关闭。');
        pool = null; // 帮助垃圾回收
      }
    });
  });
});
