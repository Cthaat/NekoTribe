// server/utils/oceanBasePool.ts
import mysql from 'mysql2/promise'

let pool: mysql.Pool | null = null

export async function initOceanBasePool() {
  if (!pool) {
    const runtimeConfig = useRuntimeConfig()
    
    pool = mysql.createPool({
      host: runtimeConfig.oceanbaseHost,
      port: Number(runtimeConfig.oceanbasePort) || 2881,
      user: runtimeConfig.oceanbaseUser,
      password: runtimeConfig.oceanbasePassword,
      database: runtimeConfig.oceanbaseDatabase,
      connectionLimit: 10
    })
    
    console.log('OceanBase 连接池已创建')
  }
  
  return pool
}

export async function getOceanBaseConnection() {
  const pool = await initOceanBasePool()
  return await pool.getConnection()
}

/**
 * 执行查询的便捷方法
 * @param sql SQL 查询语句
 * @param params 查询参数
 * @returns 查询结果
 */
export async function executeQuery(sql: string, params?: any[]) {
  const connection = await getOceanBaseConnection()
  try {
    const [rows] = await connection.execute(sql, params)
    return rows
  } finally {
    connection.release()
  }
}

/**
 * 关闭连接池
 */
export async function closeOceanBasePool() {
  if (pool) {
    await pool.end()
    pool = null
    console.log('OceanBase 连接池已关闭')
  }
}