export default defineEventHandler(async event => {
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
      WHERE ROWNUM <= 10
    `;

    const result = await connection.execute(suggestionSql);

    console.log('Search Result:', result.rows);

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
