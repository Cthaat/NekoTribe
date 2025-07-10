export default defineEventHandler(async event => {
  // 获取当前登录用户信息
  const user: Auth = event.context.auth as Auth;
  // 获取 tweetId 路径参数
  const userId: string = getRouterParam(event, 'userId') as string;

  // 获取 query 参数
  const query: TweetMutualFollowsPayload = getQuery(
    event
  ) as TweetMutualFollowsPayload;

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
    const mutualFollowsSql = `
    SELECT *
    FROM (
        SELECT
            u.display_name,
            u.avatar_url,
            ROW_NUMBER() OVER (ORDER BY u.user_id) AS rn
        FROM n_users u
        WHERE
            fn_get_user_relationship(:user_id_a, u.user_id) IN ('follow', 'mutual')
            AND fn_get_user_relationship(:user_id_b, u.user_id) IN ('follow', 'mutual')
            AND u.user_id NOT IN (:user_id_a, :user_id_b)
    )
    WHERE rn > (:page - 1) * :pagesize
      AND rn <= :page * :pagesize
    ORDER BY rn
    `;

    const mutualFollowsCountSql = `
    SELECT
      count(*) AS total_count
    FROM n_users u
    WHERE
        fn_get_user_relationship(:user_id_a, u.user_id) IN ('follow', 'mutual')
        AND fn_get_user_relationship(:user_id_b, u.user_id) IN ('follow', 'mutual')
        AND u.user_id NOT IN (:user_id_a, :user_id_b)
    ORDER BY u.user_id
    `;

    const result = await connection.execute(mutualFollowsSql, {
      user_id_a: userId,
      user_id_b: user.userId,
      page,
      pagesize: pageSize
    });

    // 获取总数
    const totalCountResult = await connection.execute(mutualFollowsCountSql, {
      user_id_a: userId,
      user_id_b: user.userId
    });

    const totalCount = totalCountResult.rows[0][0] as number;

    const mutualFollows: MutualFollowsItem[] = await Promise.all(
      result.rows.map(
        async (row: MutualFollowsRow) =>
          ({
            displayName: row[0],
            avatarUrl: row[1],
            rn: row[2]
          }) as MutualFollowsItem
      )
    );

    return {
      success: true,
      data: {
        list: mutualFollows,
        totalCount
      },
      code: 200,
      timestamp: new Date().toISOString()
    } as MutualFollowsResponse;
  } finally {
    await connection.close();
  }
});
