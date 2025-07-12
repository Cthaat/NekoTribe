export default defineEventHandler(async event => {
  // 只有 GET、POST、PUT、DELETE 等 HTTP 方法才进行限流检查
  if (!event.node.req.method) return;

  // 获取 Redis 实例
  const redis = event.context.redis;
  if (!redis) {
    console.warn('Redis 未初始化，跳过限流检查');
    return;
  }

  const ip =
    event.node.req.headers['x-forwarded-for'] ||
    event.node.req.socket.remoteAddress;
  const now = Date.now();
  const redisKey = `rate_limit:${ip}`;

  try {
    // 从 Redis 获取当前 IP 的限流信息
    const existingData = await redis.get(redisKey);
    let info = { count: 0, last: now };

    if (existingData) {
      info = JSON.parse(existingData);
    }

    // 1分钟窗口限制10次
    if (now - info.last > 60_000) {
      info.count = 1;
      info.last = now;
    } else {
      info.count++;
    }

    // 将更新后的数据存储到 Redis，设置过期时间为2分钟
    await redis.setex(redisKey, 120, JSON.stringify(info));

    // 如果超过限制，直接抛出错误，阻止后续执行
    if (info.count > 10) {
      throw createError({
        statusCode: 429,
        message: '请求过于频繁，请稍后再试',
        data: {
          success: false,
          message: '请求过于频繁，请稍后再试',
          code: 429,
          timestamp: new Date().toISOString()
        } as ErrorResponse
      });
    }
  } catch (err: any) {
    // 如果是限流错误，直接抛出
    if (err.statusCode === 429) {
      throw err;
    }
    // 如果是 Redis 错误，记录日志但不影响正常请求
    console.error('Redis 限流检查失败:', err.message);
  }
});
