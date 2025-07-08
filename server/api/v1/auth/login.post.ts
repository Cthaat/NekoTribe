import bcrypt from 'bcrypt';
import jwt from 'jsonwebtoken';
import crypto from 'crypto';

const runtimeConfig = useRuntimeConfig();


// 事件处理函数：处理获取邮箱验证码的请求
export default defineEventHandler(async (event) => {
  const body = await readBody<LoginPayload>(event)
  
  // 参数验证
  if (!body.account || !body.password) {
    throw createError({
      statusCode: 400,
      message: '账号和密码不能为空',
      statusMessage: 'Bad Request',
      data: {
        success: false,
        message: '账号和密码不能为空',
        code: 400,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  }

  const connection = await getOracleConnection();

  try {
    // 2. 检查邮箱是否已注册
    const checkSql = `SELECT COUNT(*) AS count FROM n_users WHERE email = :email OR username = :username`;
    const checkResult = await connection.execute(checkSql, { email: body.account, username: body.account });
    const checkResultRow: checkResultRow = checkResult.rows?.[0] as checkResultRow || [];
    const userCount = checkResultRow[0] || 0;
    if (userCount === 0) {
      throw createError({
        statusCode: 409,
        message: '该邮箱或用户名未注册',
        statusMessage: '邮箱或用户名未注册',
        data: {
          success: false,
          message: '该邮箱或用户名未注册',
          code: 409,
          timestamp: new Date().toISOString()
        } as ErrorResponse
      });
    }

    // 3. 验证密码
    const userSql = `SELECT 
    USER_ID,
    USERNAME,
    EMAIL,
    DISPLAY_NAME,
    AVATAR_URL,
    IS_VERIFIED,
    PASSWORD_HASH
    FROM n_users WHERE email = :email OR username = :username`;

    const userResult = await connection.execute(userSql, { email: body.account, username: body.account });

    // 取第一行数据
    const row: LoginUserRow = userResult.rows?.[0] as LoginUserRow || [];

    // 4. 验证密码
    const isPasswordValid = await bcrypt.compare(body.password, row[6]);
    if (!isPasswordValid) {
      throw createError({
        statusCode: 401,
        message: '账号或密码错误',
        statusMessage: 'Unauthorized',
        data: {
          success: false,
          message: '账号或密码错误',
          code: 401,
          timestamp: new Date().toISOString()
        } as ErrorResponse
      });
    }

    // TODO: 设置JWT

    // TODO: 更新各种时间

  } finally {
    // 5. 关闭数据库连接
    await connection.close();
  }
})