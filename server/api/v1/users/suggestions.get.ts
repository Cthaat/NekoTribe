export default defineEventHandler(async event => {
  // 获取 query 参数
  const query: SuggestionUsersPayload = getQuery(
    event
  ) as SuggestionUsersPayload;

  // 提取参数
  const limit: number = (query.limit || 10) as number;

  const getOracleConnection = event.context.getOracleConnection;
  const connection = await getOracleConnection();

  try {
    const suggestionSql = `
    SELECT user_id
      FROM (
          SELECT u.*
          FROM n_users u
          WHERE u.is_active = 1
          ORDER BY u.followers_count DESC, u.created_at DESC
      )
      WHERE ROWNUM <= :limit
    `;

    const result = await connection.execute(suggestionSql, {
      limit
    });

    return {
      success: true,
      message: 'Search users successfully',
      data: {
        users: result.rows.map((row: ReturnSuggestionUserId[]) => ({
          userId: row[0]
        }))
      },
      code: 200,
      timestamp: new Date().toISOString()
    } as SuggestionResponse;
  } finally {
    await connection.close();
  }
});
