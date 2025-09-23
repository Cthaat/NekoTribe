export default defineEventHandler(async event => {
  // 获取当前登录用户信息
  const user: Auth = event.context.auth as Auth;

  // 获取 query 参数
  const query: TweetBlockedPayload = getQuery(
    event
  ) as TweetBlockedPayload;

  // 提取参数
  const { page = 1, pageSize = 10 } = query;

  const getOracleConnection =
    event.context.getOracleConnection;
  const connection = await getOracleConnection();

  try {
    const blockedSql = `
    SELECT *
    FROM (
        SELECT
            u.user_id,
            u.display_name,
            u.avatar_url,
            ROW_NUMBER() OVER (ORDER BY f.created_at DESC) AS rn
        FROM n_follows f
        JOIN n_users u ON f.following_id = u.user_id
        WHERE f.follower_id = :userId
          AND f.follow_type = 'block'
          AND f.is_active = 1
    )
    WHERE rn > (:page - 1) * :pagesize
      AND rn <= :page * :pagesize
    ORDER BY rn
    `;

    const blockedCountSql = `
    SELECT
      count(*) AS total_count
    FROM n_follows f
    JOIN n_users u ON f.following_id = u.user_id
    WHERE f.follower_id = :userId
          AND f.follow_type = 'block'
          AND f.is_active = 1
    `;

    const result = await connection.execute(blockedSql, {
      userId: user.userId,
      page,
      pagesize: pageSize
    });

    // 获取总数
    const totalCountResult = await connection.execute(
      blockedCountSql,
      {
        userId: user.userId
      }
    );

    const totalCount = totalCountResult
      .rows[0][0] as number;

    const followers: TweetBlockedItem[] = await Promise.all(
      result.rows.map(
        async (row: TweetBlockedRow) =>
          ({
            displayName: row[0],
            avatarUrl: row[1],
            rn: row[2]
          }) as TweetBlockedItem
      )
    );

    return {
      success: true,
      message: '获取成功',
      data: {
        page,
        pageSize,
        list: followers,
        totalCount
      },
      code: 200,
      timestamp: new Date().toISOString()
    } as TweetBlockedResponse;
  } finally {
    await connection.close();
  }
});
