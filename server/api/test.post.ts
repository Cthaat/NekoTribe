import { getOracleConnection } from '~/server/utils/oraclePool'

export default defineEventHandler(async (event) => {
  let connection

  try {
    connection = await getOracleConnection()// 执行查询
    const result = await connection.execute('SELECT * FROM n_users')
    return { data: result.rows }
  } catch (error) {
    console.error('获取 Oracle 连接失败:', error)
    return { error: '获取 Oracle 连接失败' }
  } finally {
    if (connection) {
      await connection.close()
    }
  }
});