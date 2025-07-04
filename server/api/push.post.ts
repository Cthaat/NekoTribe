// server/api/push.post.ts
import type { Redis } from 'ioredis'

export default defineEventHandler(async (event) => {
  const { userId, message } = await readBody(event)

  if (!userId || !message) {
    throw createError({
      statusCode: 400,
      statusMessage: 'Missing "userId" or "message" in request body',
    })
  }

  // 从上下文中获取 Redis publisher 实例
  const redisPublisher = event.context.redisPublisher as Redis

  if (!redisPublisher) {
    throw createError({
      statusCode: 500,
      statusMessage: 'Redis publisher is not available. Check server configuration.',
    })
  }

  // 构建要推送给客户端的最终数据载荷
  const payload = {
    type: 'NOTIFICATION',
    data: {
      id: Date.now(),
      text: message,
      timestamp: new Date().toISOString(),
    },
  }

  // 将包含目标 userId 和数据载荷的消息发布到 Redis 频道
  try {
    await redisPublisher.publish('global-notifications', JSON.stringify({ userId, payload }))
    return { success: true, detail: `Notification for user ${userId} published to Redis.` }
  } catch (error) {
    console.error('Failed to publish notification to Redis:', error)
    throw createError({
      statusCode: 500,
      statusMessage: 'Failed to publish notification.',
    })
  }
})