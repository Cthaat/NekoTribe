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
    SELECT *
    FROM (
        SELECT
            u.display_name,
            u.avatar_url,
            l.like_type,
            ROW_NUMBER() OVER (ORDER BY l.created_at DESC) AS rn
        FROM n_likes l
        JOIN n_users u ON l.user_id = u.user_id
        WHERE l.tweet_id = :tweet_id
    )
    WHERE rn > (:page - 1) * :pagesize
      AND rn <= :page * :pagesize
    ORDER BY rn
    `;
    const likesCountSql = `
    SELECT
      count(*) AS total_count
    FROM n_likes l
    JOIN n_users u ON l.user_id = u.user_id
    WHERE l.tweet_id = :tweet_id
    `;

    const result = await connection.execute(likesSql, {
      tweet_id: tweetId,
      page,
      pagesize: pageSize
    });

    // 获取总数
    const countResult = await connection.execute(likesCountSql, {
      tweet_id: tweetId
    });

    // 提取总数
    const totalCount: number = countResult.rows[0][0] as number;

    // 处理点赞数据
    const likes: TweetGetReLikesItem[] = await Promise.all(
      result.rows.map(
        async (row: TweetGetReLikesRow) =>
          ({
            displayName: row[0],
            avatarUrl: row[1],
            likeType: row[2],
            rn: row[3]
          }) as TweetGetReLikesItem
      )
    );

    // 返回响应
    return {
      success: true,
      message: '获取成功',
      data: {
        page,
        pageSize,
        likes,
        totalCount
      },
      code: 200,
      timestamp: new Date().toISOString()
    } as TweetGetReLikesResponse;
  } finally {
    await connection.close();
  }
});
