import jwt from 'jsonwebtoken';
import { getRequestURL, getHeader } from 'h3'; // 导入 getHeader

const runtimeConfig = useRuntimeConfig();

const API_PREFIX = '/api/';
const API_LOGIN = '/api/v1/auth/';

export default defineEventHandler(async event => {
  const url = getRequestURL(event).pathname;

  if (
    !url.startsWith(API_PREFIX) ||
    url.startsWith(API_LOGIN)
  ) {
    return;
  }

  // 同时处理 Header 和 Cookie

  // 1. 优先从 Authorization 请求头中获取 Token
  const authHeader = getHeader(event, 'Authorization');
  let token: string | undefined;

  if (authHeader && authHeader.startsWith('Bearer ')) {
    // 如果存在 Bearer token，就提取它
    token = authHeader.substring(7);
    console.log(
      '[auth.ts] 从 Authorization Header 中解析到 Token。',
      token
    );
  } else {
    // 2. 如果请求头中没有，再尝试从 Cookie 中获取
    token = getCookie(event, 'access_token');
    if (token) {
      console.log('[auth.ts] 从 Cookie 中解析到 Token。');
    }
  }
  console.log(
    '[auth.ts] 获取到的 Cookie Token:',
    getCookie(event, 'access_token')
  );
  console.log('[auth.ts] 最终用于验证的 Token:', token);

  // 3. 如果两种方式都获取不到 Token，则抛出未登录错误
  if (!token) {
    console.log('[auth.ts] 未提供 Token，抛出未登录错误。');
    // 抛出未登录错误
    throw createError({
      statusCode: 401,
      statusMessage: '未提供认证凭证',
      data: {
        success: false,
        message: '请先登录或提供有效的Token',
        code: 401,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  }

  // --- 后续的数据库和 JWT 验证逻辑保持不变 ---

  const getOracleConnection =
    event.context.getOracleConnection;
  const connection = await getOracleConnection();

  try {
    const payload = jwt.verify(
      token,
      runtimeConfig.accessSecret
    );
    event.context.auth = payload;

    const auth: Auth = payload as Auth;

    // 更新用户的最后访问时间
    const updateSql = `
      UPDATE n_user_sessions
      SET last_accessed_at = SYSDATE
      WHERE user_id = :userId
      AND (
        DBMS_LOB.COMPARE(access_token, :accessToken) = 0 OR 
        DBMS_LOB.COMPARE(refresh_token, :accessToken) = 0
      )
    `; // 注意：您的 SQL 可能需要调整，取决于您希望用哪个 token 来更新会话

    await connection.execute(
      updateSql,
      {
        userId: auth.userId,
        accessToken: token
      },
      { autoCommit: true }
    );
  } catch (err) {
    console.log('[auth.ts] Token验证失败:', err);
    // 当 jwt.verify 失败时，这里的错误处理是正确的
    throw createError({
      statusCode: 401,
      statusMessage: 'Token无效',
      data: {
        success: false,
        message: 'Token无效或已过期',
        code: 401,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  } finally {
    if (connection) {
      await connection.close();
    }
  }
});
