import bcrypt from 'bcrypt';
import { verifyCode } from '~/server/utils/auth/verifyCode';
import { getOracleConnection } from '~/server/utils/database/oraclePool';

export default defineEventHandler(async (event): Promise<RegisterResponse> => {
  const body = await readBody<registerPayload>(event)

  if (!body) {
    throw createError({
      statusCode: 400,
      message: '请求体不能为空',
      statusMessage: 'Bad Request',
      data: {
        success: false,
        message: '请求体不能为空',
        code: 400,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  }

  if(!body.email) {
    throw createError({
      statusCode: 400,
      message: '邮箱地址不能为空',
      statusMessage: 'Bad Request',
      data: {
        success: false,
        message: '邮箱地址不能为空',
        code: 400,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  }

  if(!/^\S+@\S+\.\S+$/.test(body.email)) {
    throw createError({
      statusCode: 400,
      message: '邮箱地址格式不正确',
      statusMessage: 'Bad Request',
      data: {
        success: false,
        message: '邮箱地址格式不正确',
        code: 400,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  }

  if(!body.password) {
    throw createError({
      statusCode: 400,
      message: '密码不能为空',
      statusMessage: 'Bad Request',
      data: {
        success: false,
        message: '密码不能为空',
        code: 400,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  }

  if(body.password.length < 6) {
    throw createError({
      statusCode: 400,
      message: '密码长度不能少于6个字符',
      statusMessage: 'Bad Request',
      data: {
        success: false,
        message: '密码长度不能少于6个字符',
        code: 400,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  }

  if (body.password !== body.confirmPassword) {
    throw createError({
      statusCode: 400,
      message: '密码和确认密码不匹配',
      statusMessage: 'Bad Request',
      data: {
        success: false,
        message: '密码和确认密码不匹配',
        code: 400,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  }

  if (!body.agreeToTerms) {
    throw createError({
      statusCode: 400,
      message: '必须同意服务条款',
      statusMessage: 'Bad Request',
      data: {
        success: false,
        message: '必须同意服务条款',
        code: 400,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  }

  if (!body.captcha) {
    throw createError({
      statusCode: 400,
      message: '验证码不能为空',
      statusMessage: 'Bad Request',
      data: {
        success: false,
        message: '验证码不能为空',
        code: 400,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  }

  await verifyCode(body.email, body.captcha);

  const hashedPassword: string = await bcrypt.hash(body.password, 10);

  // 这里应该添加实际的注册逻辑
  const connection = await getOracleConnection();

  try {
    // 2. 检查邮箱是否已注册
    const checkSql = `SELECT COUNT(*) AS count FROM n_users WHERE email = :email`;
    const checkResult = await connection.execute(checkSql, { email: body.email });
    const checkResultRow: checkResultRow = checkResult.rows?.[0] as checkResultRow || [];
    const userCount = checkResultRow[0] || 0;
    if (userCount > 0) {
      throw createError({
        statusCode: 409,
        message: '该邮箱已被注册',
        statusMessage: '邮箱已存在',
        data: {
          success: false,
          message: '该邮箱已被注册',
          code: 409,
          timestamp: new Date().toISOString()
        } as ErrorResponse
      });
    }

    // 3. 插入新用户数据
    const insertSql = `
      INSERT INTO n_users (
        email,
        username,
        password_hash,
        display_name,
        bio,
        location,
        is_verified
    )
      VALUES (:email, :username, :password_hash, :display_name, :bio, :location, :is_verified)
    `;
    await connection.execute(insertSql, {
      email: body.email,
      username: body.username,
      password_hash: hashedPassword,
      display_name: body.displayName,
      bio: body.bio,
      location: body.location,
      is_verified: 1 // 默认设置为已验证
    }, { autoCommit: true });

    const selectSql = `SELECT USER_ID, USERNAME, EMAIL, DISPLAY_NAME, AVATAR_URL, IS_VERIFIED, CREATED_AT FROM n_users WHERE email = :email`;
    const userResult = await connection.execute(selectSql, { email: body.email });

    // 取第一行数据
    const row: UserRow = userResult.rows?.[0] as UserRow || [];

    // 4. 返回注册成功
    return {
      success: true,
      message: '注册成功',
      data: {
        userId: row[0],
        username: row[1],
        email: row[2],
        displayName: row[3],
        avatar: row[4],
        isVerified: row[5] === 1, // IS_VERIFIED 为 1 表示已验证
        createdAt: row[6]
      },
      code: 200,
      timestamp: new Date().toISOString()
    } as RegisterResponse;
  } finally {
    // 5. 关闭数据库连接
    await connection.close();
  }
});