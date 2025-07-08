import RedisClient from '~/server/utils/auth/redisClient'
import Redis from 'ioredis'

const redis: Redis = RedisClient.getInstance()

/**
 * 校验验证码工具函数
 * @param account 邮箱或手机号
 * @param code 用户输入的验证码
 * @returns 校验通过返回 true，否则抛出错误
 */
export async function verifyCode(account: string, code: string): Promise<boolean> {
  const storedCode: string | null = await redis.get(`verification_code:${account}`)
  if (!storedCode) {
    throw createError({
      statusCode: 400,
      message: '验证码不存在或已过期',
      statusMessage: '验证码不存在或已过期',
      data: {
        success: false,
        message: '验证码不存在或已过期',
        code: 400,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    })
  }
  if (code !== storedCode) {
    throw createError({
      statusCode: 401,
      message: '验证码错误',
      statusMessage: '验证码错误',
      data: {
        success: false,
        message: '验证码错误',
        code: 401,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    })
  }
  await redis.del(`verification_code:${account}`)
  return true
}