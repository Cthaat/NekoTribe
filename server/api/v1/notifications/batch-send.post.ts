import oracledb from 'oracledb';

export default defineEventHandler(async event => {
  // 获取当前登录用户信息（作为触发者）
  const user: Auth = event.context.auth as Auth;

  // 获取请求体参数，添加错误处理
  let body: any;
  try {
    body = await readBody(event);
  } catch (error: any) {
    throw createError({
      statusCode: 400,
      message:
        '请求体格式错误，请确保发送有效的 JSON 格式数据',
      data: {
        success: false,
        message: '请求体格式错误: ' + error.message,
        code: 400,
        timestamp: new Date().toISOString()
      }
    });
  }

  // 验证body不为空
  if (!body || typeof body !== 'object') {
    throw createError({
      statusCode: 400,
      message: '请求体为空或格式不正确',
      data: {
        success: false,
        message: '请求体为空或格式不正确',
        code: 400,
        timestamp: new Date().toISOString()
      }
    });
  }

  // 验证必需参数
  const {
    userIds, // 接收通知的用户ID数组
    type, // 通知类型
    title, // 通知标题
    message, // 通知内容
    relatedType, // 相关类型
    relatedId, // 相关ID
    priority = 'normal' // 优先级
  } = body;

  // 参数验证
  if (
    !userIds ||
    !Array.isArray(userIds) ||
    userIds.length === 0
  ) {
    throw createError({
      statusCode: 400,
      message: '缺少接收者用户ID列表或列表为空',
      data: {
        success: false,
        message: '缺少接收者用户ID列表或列表为空',
        code: 400,
        timestamp: new Date().toISOString()
      }
    });
  }

  if (!type) {
    throw createError({
      statusCode: 400,
      message: '缺少通知类型',
      data: {
        success: false,
        message: '缺少通知类型',
        code: 400,
        timestamp: new Date().toISOString()
      }
    });
  }

  if (!message) {
    throw createError({
      statusCode: 400,
      message: '缺少通知内容',
      data: {
        success: false,
        message: '缺少通知内容',
        code: 400,
        timestamp: new Date().toISOString()
      }
    });
  }

  // 验证通知类型
  const validTypes = [
    'like',
    'retweet',
    'comment',
    'follow',
    'mention',
    'system'
  ];
  if (!validTypes.includes(type)) {
    throw createError({
      statusCode: 400,
      message: `无效的通知类型，必须是以下之一: ${validTypes.join(', ')}`,
      data: {
        success: false,
        message: `无效的通知类型`,
        code: 400,
        timestamp: new Date().toISOString()
      }
    });
  }

  // 验证优先级
  const validPriorities = [
    'low',
    'normal',
    'high',
    'urgent'
  ];
  if (!validPriorities.includes(priority)) {
    throw createError({
      statusCode: 400,
      message: `无效的优先级，必须是以下之一: ${validPriorities.join(', ')}`,
      data: {
        success: false,
        message: `无效的优先级`,
        code: 400,
        timestamp: new Date().toISOString()
      }
    });
  }

  const getOracleConnection =
    event.context.getOracleConnection;
  const connection = await getOracleConnection();

  try {
    // 将用户ID数组转换为逗号分隔的字符串
    const userIdsString = userIds.join(',');

    // 调用批量创建通知的存储过程
    const result = await connection.execute(
      `BEGIN
        sp_batch_create_notifications(
          p_user_ids => :p_user_ids,
          p_type => :p_type,
          p_title => :p_title,
          p_message => :p_message,
          p_related_type => :p_related_type,
          p_related_id => :p_related_id,
          p_actor_id => :p_actor_id,
          p_priority => :p_priority,
          p_result => :p_result
        );
      END;`,
      {
        p_user_ids: userIdsString,
        p_type: type,
        p_title: title || '',
        p_message: message,
        p_related_type: relatedType || null,
        p_related_id: relatedId || null,
        p_actor_id: user.userId, // 当前登录用户作为触发者
        p_priority: priority,
        p_result: {
          dir: oracledb.BIND_OUT,
          type: oracledb.STRING,
          maxSize: 500
        }
      },
      { autoCommit: true }
    );

    // 获取存储过程返回结果
    const procedureResult = result.outBinds?.p_result || '';

    // 检查结果
    if (procedureResult.startsWith('SUCCESS')) {
      // 从结果中提取成功和失败的数量
      const successMatch =
        procedureResult.match(/成功创建(\d+)个通知/);
      const failedMatch =
        procedureResult.match(/失败(\d+)个/);

      const successCount = successMatch
        ? parseInt(successMatch[1])
        : 0;
      const failedCount = failedMatch
        ? parseInt(failedMatch[1])
        : 0;

      return {
        success: true,
        message: '批量通知发送完成',
        data: {
          totalRequested: userIds.length,
          successCount: successCount,
          failedCount: failedCount,
          type: type,
          message: message,
          procedureMessage: procedureResult
        },
        code: 200,
        timestamp: new Date().toISOString()
      };
    } else {
      // 存储过程返回错误
      throw new Error(procedureResult);
    }
  } catch (error: any) {
    console.error('批量发送通知失败:', error);

    throw createError({
      statusCode: 500,
      message: '批量发送通知失败',
      data: {
        success: false,
        message: error.message || '服务器内部错误',
        code: 500,
        timestamp: new Date().toISOString()
      }
    });
  } finally {
    await connection.close();
  }
});
