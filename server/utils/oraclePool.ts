// server/utils/oraclePool.ts
import oracledb from 'oracledb'

let pool: oracledb.Pool | null = null

export async function initOraclePool() {
  if (!pool) {
    const runtimeConfig = useRuntimeConfig()
    
    pool = await oracledb.createPool({
      user: runtimeConfig.oracleUser,
      password: runtimeConfig.oraclePassword,
      connectString: `${runtimeConfig.oracleHost}:${runtimeConfig.oraclePort}/${runtimeConfig.oracleServiceName}`,

      // 使用环境变量中的连接池配置
      poolMin: Number(runtimeConfig.oraclePoolMin) || 2,
      poolMax: Number(runtimeConfig.oraclePoolMax) || 10,
      poolIncrement: Number(runtimeConfig.oraclePoolIncrement) || 1,

      // 其他配置
      poolTimeout: 300,  // 连接空闲300秒后释放
      queueMax: 0,       // 等待队列无限制
      queueTimeout: 60000 // 等待超时60秒
    })
    
    console.log('Oracle 连接池已创建')
  }
  
  return pool
}

export async function getOracleConnection() {
  const pool = await initOraclePool()
  return await pool.getConnection()
}