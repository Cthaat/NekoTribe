export default defineEventHandler(async event => {
  // 获取当前登录用户信息
  const user: Auth = event.context.auth as Auth;
  // 获取 tweetId 路径参数
  const userId: string = getRouterParam(event, 'userId') as string;

  // 获取 query 参数
  const query: TweetFollowingPayload = getQuery(event) as TweetFollowingPayload;

  // 提取参数
  const { page = 1, pageSize = 10 } = query;

  if (!userId) {
    throw createError({
      statusCode: 400,
      message: '缺少用户ID',
      data: {
        success: false,
        message: '缺少用户ID',
        code: 400,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  }

  const getOracleConnection = event.context.getOracleConnection;
  const connection = await getOracleConnection();

  try {
    const followingSql = `
    SELECT *
    FROM (
        SELECT
            u.display_name,
            u.avatar_url,
            ROW_NUMBER() OVER (ORDER BY f.created_at DESC) AS rn
        FROM n_follows f
        JOIN n_users u ON f.follower_id = u.user_id
        WHERE u.user_id = :userId
          AND f.follow_type = 'follow'
          AND f.is_active = 1
    )
    WHERE rn > (:page - 1) * :pagesize
      AND rn <= :page * :pagesize
    ORDER BY rn
    `;

    const followingCountSql = `
    SELECT
      count(*) AS total_count
    FROM n_follows f
    JOIN n_users u ON f.follower_id = u.user_id
    WHERE u.user_id = :userId
          AND f.follow_type = 'follow'
          AND f.is_active = 1
    `;

    const result = await connection.execute(followingSql, {
      userId,
      page,
      pagesize: pageSize
    });

    // 获取总数
    const totalCountResult = await connection.execute(followingCountSql, {
      userId
    });

    const totalCount = totalCountResult.rows[0][0] as number;

    const followings: TweetGetFollowingItem[] = await Promise.all(
      result.rows.map(
        async (row: TweetGetFollowingRow) =>
          ({
            displayName: row[0],
            avatarUrl: row[1],
            rn: row[2]
          }) as TweetGetFollowingItem
      )
    );

    return {
      success: true,
      data: {
        list: followings,
        totalCount
      },
      code: 200,
      timestamp: new Date().toISOString()
    } as TweetGetFollowingResponse;
  } finally {
    await connection.close();
  }
});
