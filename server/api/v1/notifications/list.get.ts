// 数据库行转换为对象
function rowToNotificationItem(row: NotificationRow): NotificationItem {
  return {
    notificationId: row[0],
    userId: row[1],
    type: row[2],
    title: row[3],
    message: row[4],
    relatedType: row[5],
    relatedId: row[6],
    actorId: row[7],
    isRead: row[8],
    priority: row[9],
    createdAt: row[10],
    readAt: row[11],
    recipientUsername: row[12],
    recipientDisplayName: row[13],
    recipientAvatarUrl: row[14],
    actorUsername: row[15],
    actorDisplayName: row[16],
    actorAvatarUrl: row[17],
    actorIsVerified: row[18],
    relatedTweetContent: row[19],
    relatedCommentContent: row[20],
    readStatusDesc: row[21],
    priorityDesc: row[22],
    typeDesc: row[23],
    timeCategory: row[24],
    hoursSinceCreated: row[25],
    isRecent: row[26],
    totalCount: row[27],
    rn: row[28]
  };
}

export default defineEventHandler(async event => {
  // 获取当前登录用户信息
  const user: Auth = event.context.auth as Auth;

  // 获取 query 参数
  const query: NotificationSearchPayload = getQuery(
    event
  ) as NotificationSearchPayload;

  // 提取参数
  const { type = 'all', page = 1, pageSize = 10, unreadOnly = false } = query;

  const getOracleConnection = event.context.getOracleConnection;
  const connection = await getOracleConnection();

  try {
    const notificationSql = `
    WITH notification_filter AS (
        SELECT 
            n.*,
            COUNT(*) OVER() AS total_count,
            ROW_NUMBER() OVER(ORDER BY n.created_at DESC) AS rn
        FROM v_notifications_detail n
        WHERE 1=1
            AND n.user_id = :user_id
            AND (:type = 'all' OR n.type = :type)
            AND (:unread_only = 0 OR n.is_read = 0)
            AND n.user_id IN (SELECT user_id FROM n_users WHERE is_active = 1)
    )
    SELECT 
        notification_id,
        user_id,
        type,
        title,
        message,
        related_type,
        related_id,
        actor_id,
        is_read,
        priority,
        created_at,
        read_at,
        recipient_username,
        recipient_display_name,
        recipient_avatar_url,
        actor_username,
        actor_display_name,
        actor_avatar_url,
        actor_is_verified,
        related_tweet_content,
        related_comment_content,
        read_status_desc,
        priority_desc,
        type_desc,
        time_category,
        hours_since_created,
        is_recent,
        total_count
    FROM notification_filter
    WHERE rn BETWEEN ((:page - 1) * :page_size + 1) AND (:page * :page_size)
    ORDER BY created_at DESC
    `;

    // 执行查询
    const result = await connection.execute(notificationSql, {
      user_id: user.userId,
      type: type,
      unread_only: unreadOnly ? 1 : 0,
      page: page,
      page_size: pageSize
    });

    // 处理查询结果
    const rows = result.rows as NotificationRow[];
    const notifications = rows.map(row => rowToNotificationItem(row));

    // 计算分页信息
    const totalCount =
      notifications.length > 0 ? notifications[0].totalCount : 0;
    const totalPages = Math.ceil(totalCount / pageSize);
    const hasNext = page < totalPages;
    const hasPrev = page > 1;

    // 返回成功响应
    return {
      success: true,
      message: '获取通知列表成功',
      data: {
        type: type,
        page: page,
        pageSize: pageSize,
        notifications: notifications,
        totalCount: totalCount,
        unreadOnly: unreadOnly,
        hasNext: hasNext,
        hasPrev: hasPrev,
        totalPages: totalPages
      },
      code: 200,
      timestamp: new Date().toISOString()
    };
  } catch (error) {
    throw createError({
      statusCode: 500,
      statusMessage: '获取通知列表失败',
      data: error
    });
  } finally {
    await connection.close();
  }
});
