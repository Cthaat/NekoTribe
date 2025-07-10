export default defineEventHandler(async event => {
  // 获取当前登录用户信息
  const user: Auth = event.context.auth as Auth;
  // 获取 tweetId 路径参数
  const tweetId = getRouterParam(event, 'tweetId');

  // 获取 query 参数
  const query: TweetLikesPayload = getQuery(event) as TweetLikesPayload;

  // 提取参数
  const { page = 1, pageSize = 10 } = query;

  if (!tweetId) {
    throw createError({
      statusCode: 400,
      message: '缺少推文ID',
      data: {
        success: false,
        message: '缺少推文ID',
        code: 400,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  }

  const getOracleConnection = event.context.getOracleConnection;
  const connection = await getOracleConnection();

  try {
    const likesSql = `
    SELECT
      u.display_name,
      u.avatar_url,
      l.LIKE_TYPE
    FROM n_likes l
    JOIN n_users u ON l.user_id = u.user_id
    WHERE l.tweet_id = :tweet_id
      AND l.like_type = 'like'
    ORDER BY l.created_at DESC
    `;
  } finally {
    await connection.close();
  }
});
