export default defineEventHandler(async event => {
  const getOracleConnection = event.context.getOracleConnection;
  const connection = await getOracleConnection();
  try {
    // 查询所有用户
    const result = await connection.execute('SELECT * FROM n_users');
    return {
      success: true,
      message: 'Oracle 数据库连接成功',
      data: result.rows,
      code: 200,
      timestamp: new Date().toISOString()
    };
  } catch (err: any) {
    // 直接抛出错误，让框架自动处理
    throw createError({
      statusCode: 500,
      message: 'Oracle 数据库连接失败',
      data: {
        success: false,
        message: 'Oracle 数据库连接失败',
        error: err.message,
        code: 500,
        timestamp: new Date().toISOString()
      }
    });
  } finally {
    // 关闭数据库连接
    if (connection) {
      await connection.close();
    }
  }
});
