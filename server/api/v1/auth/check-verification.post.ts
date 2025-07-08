import RedisClient from '~/server/utils/redisClient' // 引入 Redis 客户端单例
import Redis from 'ioredis'

const redis: Redis = RedisClient.getInstance()              // 获取 Redis 实例

// 事件处理函数：处理获取邮箱验证码的请求
export default defineEventHandler(async (event) => {
  const body = await readBody<CheckVerificationPayload>(event)
  
  // 从redis中获取验证码
  const storedCode: string | null = await redis.get(`verification_code:${body.account}`)

  if (!storedCode) {
    return createError({
      statusCode: 400,
      message: 'Verification code not found',
      statusMessage: 'Verification code not found',
      data: {
        success: false,
        message: 'Verification code not found',
        code: 400,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  }

  // 校验验证码
  if (body.code !== storedCode) {
    return createError({
      statusCode: 401,
      message: 'Invalid verification code',
      statusMessage: 'Invalid verification code',
      data: {
        success: false,
        message: 'Invalid verification code',
        code: 401,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  }

  // 验证码校验通过，删除redis中的验证码
  await redis.del(`verification_code:${body.account}`)

  return {
    success: true,
    message: 'Verification code checked successfully',
    data: {
      account: body.account
    },
    code: 200,
    timestamp: new Date().toISOString()
  } as CheckVerificationResponse
})