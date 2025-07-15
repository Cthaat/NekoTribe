import jwt from 'jsonwebtoken';
import { getRequestURL } from 'h3';

const runtimeConfig = useRuntimeConfig();

// 只对 API 路径做鉴权
const API_PREFIX = '/api/';
// 定义 Auth 接口
const API_LOGIN = '/api/v1/auth/';

export default defineEventHandler(async event => {
  const url = getRequestURL(event).pathname;

  // 如果不是 API 请求，直接放行（即前端页面切换不鉴权）
  if (
    !url.startsWith(API_PREFIX) ||
    url.startsWith(API_LOGIN)
  ) {
    return;
  }

  const getOracleConnection =
    event.context.getOracleConnection;
  const connection = await getOracleConnection();

  const token = getCookie(event, 'access_token');
  if (!token) {
    throw createError({
      statusCode: 401,
      statusMessage: '未登录',
      data: {
        success: false,
        message: '请先登录',
        code: 401,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  }
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
    SET
    last_accessed_at = SYSDATE
    WHERE user_id = :userId
    AND DBMS_LOB.COMPARE(access_token, :accessToken) = 0
    `;

    await connection.execute(
      updateSql,
      {
        userId: auth.userId,
        accessToken: token
      },
      { autoCommit: true }
    );
  } catch (err) {
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
    await connection.close();
  }
});
