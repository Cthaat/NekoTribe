import { getOracleConnection } from '~/server/utils/database/oraclePool'

export default defineEventHandler(async (event) => {
  let connection
  try {
    // 获取数据库连接
    connection = await getOracleConnection();
    // 查询所有用户
    const result = await connection.execute('SELECT * FROM n_users')
    return {
      success: true,
      message: 'Oracle 数据库连接成功',
      data: result.rows,
      code: 200,
      timestamp: new Date().toISOString()
    }
  } catch (err: any) {
    return {
      success: false,
      message: 'Oracle 数据库连接失败',
      error: err.message,
      code: 500,
      timestamp: new Date().toISOString()
    }
  } finally {
    // 关闭数据库连接
    if (connection) {
      await connection.close()
    }
  }
})