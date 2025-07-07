import RedisClient from '~/server/utils/redisClient' // 引入 Redis 客户端单例
import Mailer from '~/server/utils/mailer'           // 引入邮件发送工具
import Redis from 'ioredis'

const redis: Redis = RedisClient.getInstance()              // 获取 Redis 实例

const getRandomCode: GetRandomCode = (length = 6) => {
  return Number(Array.from({ length }).map(() => Math.floor(Math.random() * 10)).join(''))
}

// 事件处理函数：处理获取邮箱验证码的请求
export default defineEventHandler(async (event) => {
  const email: string = getQuery(event).email as string // 从请求参数中获取邮箱
  if (!email) { // 校验邮箱参数是否存在
    return createError({
      statusCode: 400, // 状态码 400，参数错误
      message: 'Email is required', // 错误信息
      statusMessage: 'Email is required', // 状态消息
      data: {
        success: false, // 操作失败
        message: 'Email is required', // 失败原因
        code: 400, // 错误码
        timestamp: new Date().toISOString() // 当前时间戳
      } as ErrorResponse
    });
  }

  const code: number = getRandomCode() // 生成6位随机验证码
  // 将验证码存入 Redis，key 为 verification_code:邮箱，过期时间5分钟
  await redis.set(`verification_code:${email}`, code, 'EX', 300)

  // 发送验证码邮件
  await Mailer.sendMail({
    to: email, // 收件人邮箱
    subject: 'Your verification code', // 邮件主题
    text: `Your verification code is ${code}`, // 邮件文本内容
    html: `<p>Your verification code is <strong>${code}</strong></p>` // 邮件 HTML 内容
  })

  return { success: true } // 返回成功响应
})