import bcrypt from 'bcrypt';
import jwt from 'jsonwebtoken';
import crypto from 'crypto';

const runtimeConfig = useRuntimeConfig();

// 事件处理函数：处理获取邮箱验证码的请求
export default defineEventHandler(async event => {
  const body = await readBody<LoginPayload>(event);
  const getOracleConnection = event.context.getOracleConnection;

  // 参数验证
  if (!body.account || !body.password) {
    throw createError({
      statusCode: 400,
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
    const checkResult = await connection.execute(checkSql, {
      email: body.account,
      username: body.account
    });
    const checkResultRow: checkResultRow =
      (checkResult.rows?.[0] as checkResultRow) || [];
    const userCount = checkResultRow[0] || 0;
    if (userCount === 0) {
      throw createError({
        statusCode: 409,
        statusMessage: '邮箱或用户名未注册',
        data: {
          success: false,
          message: '该邮箱或用户名未注册',
          data: null,
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

    const userResult = await connection.execute(userSql, {
      email: body.account,
      username: body.account
    });

    // 取第一行数据
    const row: LoginUserRow = (userResult.rows?.[0] as LoginUserRow) || [];

    // 4. 验证密码
    const isPasswordValid = await bcrypt.compare(body.password, row[6]);
    if (!isPasswordValid) {
      throw createError({
        statusCode: 401,
        statusMessage: 'Unauthorized',
        data: {
          success: false,
          message: '账号或密码错误',
          data: null,
          code: 401,
          timestamp: new Date().toISOString()
        } as ErrorResponse
      });
    }

    // 生成双Token
    const accessToken = jwt.sign(
      {
        userId: row[0],
        userName: row[1],
        type: 'access' // 标识token类型
      },
      runtimeConfig.accessSecret,
      { expiresIn: Number(runtimeConfig.accessExpiresIn) } // 15分钟过期
    );

    const refreshToken = jwt.sign(
      {
        userId: row[0],
        type: 'refresh'
      },
      runtimeConfig.refreshSecret,
      { expiresIn: Number(runtimeConfig.refreshExpiresIn) } // 30天过期
    );

    // 生成随机的refresh token ID
    const refreshTokenId = crypto.randomUUID();

    const insertSql = `
      INSERT INTO n_user_sessions (
        session_id,
        user_id,
        access_token,
        refresh_token,
        access_token_expires_at,
        refresh_token_expires_at,
        device_info,
        device_fingerprint,
        ip_address,
        user_agent
    )
      VALUES (:refreshTokenId, :userId, :accessToken, :refreshToken, :accessTokenExpiresAt, :refreshTokenExpiresAt, :deviceInfo, :deviceFingerprint, :ipAddress, :userAgent)
    `;

    const req = event.node.req;

    await connection.execute(
      insertSql,
      {
        refreshTokenId,
        userId: row[0],
        accessToken,
        refreshToken,
        accessTokenExpiresAt: new Date(
          Date.now() + Number(runtimeConfig.accessExpiresIn) * 1000
        ),
        refreshTokenExpiresAt: new Date(
          Date.now() + Number(runtimeConfig.refreshExpiresIn) * 1000
        ),
        deviceInfo: 'unknown', // 可以根据实际情况获取设备信息
        deviceFingerprint: 'unknown', // 可以根据实际情况获取设备指纹
        ipAddress:
          req.headers['x-forwarded-for']?.toString().split(',')[0]?.trim() ||
          req.socket.remoteAddress ||
          'unknown',
        userAgent: event.node.req.headers['user-agent'] || 'unknown'
      },
      { autoCommit: true }
    );

    // 设置双Cookie
    setCookie(event, 'access_token', accessToken, {
      httpOnly: true,
      secure: false,
      maxAge: 15 * 60 // 15分钟
    });

    setCookie(event, 'refresh_token', refreshToken, {
      httpOnly: true,
      secure: false,
      maxAge: 30 * 24 * 60 * 60 // 30天
    });

    const updateUserTimeSql = `
      UPDATE n_users
      SET last_login_at = :lastLoginAt
      WHERE email = :email OR username = :username
    `;
    await connection.execute(
      updateUserTimeSql,
      {
        lastLoginAt: new Date(),
        email: body.account,
        username: body.account
      },
      { autoCommit: true }
    );

    const selectSql = `
    SELECT * FROM n_users
    WHERE email = :email OR username = :username`;

    const userInfo = await connection.execute(selectSql, {
      email: body.account,
      username: body.account
    });
    // 取第一行数据
    const userInfoRow: LoginUserInfo =
      (userInfo.rows?.[0] as LoginUserInfo) || [];

    return {
      success: true,
      message: '登录成功',
      data: {
        user: {
          userInfo: userInfoRow
        },
        token: accessToken,
        refreshToken: refreshToken
      },
      code: 200,
      timestamp: new Date().toISOString()
    } as LoginResponse;
  } finally {
    // 5. 关闭数据库连接
    await connection.close();
  }
});
