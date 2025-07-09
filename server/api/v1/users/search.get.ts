export default defineEventHandler(async event => {
  // 获取 query 参数
  const query: SearchUsersPayload = getQuery(event) as SearchUsersPayload;

  // 提取参数
  const q: string = (query.q || '') as string;
  const page: number = (query.page || 1) as number;
  const pageSize: number = (query.pageSize || 10) as number;

  const getOracleConnection = event.context.getOracleConnection;
  const connection = await getOracleConnection();

  try {
    const searchSql = `
    SELECT username, display_name
    FROM (
      SELECT
        u.*,
        ROW_NUMBER() OVER (ORDER BY u.created_at DESC) AS rn
      FROM n_users u
      WHERE u.is_active = 1
        AND (
          u.username LIKE '%' || :q || '%'
          OR u.display_name LIKE '%' || :q || '%'
          OR :q IS NULL OR :q = ''
        )
    )
    WHERE rn BETWEEN (:page - 1) * :pageSize + 1 AND :page * :pageSize
    `;

    const result = await connection.execute(searchSql, {
      q,
      page,
      pageSize
    });

    console.log('Search Result:', result.rows);

    return {
      success: true,
      message: 'Search users successfully',
      data: {
        users: result.rows.map((row: ReturnUserInfo[]) => ({
          username: row[0],
          displayName: row[1]
        }))
      },
      code: 200,
      timestamp: new Date().toISOString()
    } as SearchUsersResponse;
  } finally {
    await connection.close();
  }
});
