import RedisClient from '~/server/utils/redisClient' // 引入 Redis 客户端单例
import Mailer from '~/server/utils/mailer'           // 引入邮件发送工具
import Redis from 'ioredis'

const redis: Redis = RedisClient.getInstance()              // 获取 Redis 实例

const getRandomCode: GetRandomCode = (length = 6) => {
  return Number(Array.from({ length }).map(() => Math.floor(Math.random() * 10)).join(''))
}

// 事件处理函数：处理获取邮箱验证码的请求
export default defineEventHandler(async (event) => {
  const body = await readBody<GetVerificationPayload>(event)
  if (!body.account) { // 校验账号参数是否存在
    return createError({
      statusCode: 400, // 状态码 400，参数错误
      message: 'account is required', // 错误信息
      statusMessage: 'account is required', // 状态消息
      data: {
        success: false, // 操作失败
        message: 'account is required', // 失败原因
        code: 400, // 错误码
        timestamp: new Date().toISOString() // 当前时间戳
      } as ErrorResponse
    });
  }

  // 检查是否过去一分钟，如果不到一分钟，禁止调用
  const lastRequestTime: string | null = await redis.get(`last_request_time:${body.account}`)
  const currentTime: number = Date.now()
  if (lastRequestTime) {
    return createError({
      statusCode: 429, // 状态码 429，请求过于频繁
      message: 'Too many requests, please try again later', // 错误信息
      statusMessage: 'Too many requests', // 状态消息
      data: {
        success: false, // 操作失败
        message: 'Too many requests, please try again later', // 失败原因
        code: 429, // 错误码
        timestamp: new Date().toISOString() // 当前时间戳
      } as ErrorResponse
    });
  }

  const code: number = getRandomCode() // 生成6位随机验证码
  // 将验证码存入 Redis，key 为 verification_code:账号，过期时间5分钟

  await redis.set(`verification_code:${body.account}`, code, 'EX', 300)

  // 记录请求时间
  await redis.set(`last_request_time:${body.account}`, currentTime.toString(), 'EX', 60) // 设置过期时间为60秒


  // 发送验证码邮件
  await Mailer.sendMail({
    to: body.account, // 收件人邮箱
    subject: 'Your verification code', // 邮件主题
    text: `Your verification code is ${code}`, // 邮件文本内容
    html: `<p>Your verification code is <strong>${code}</strong></p>` // 邮件 HTML 内容
  })

  return {
    success: true,
    message: 'Verification code sent successfully',
    data: {
      account: body.account
    },
    code: 200,
    timestamp: new Date().toISOString()
  } as GetVerificationResponse // 返回成功响应
})