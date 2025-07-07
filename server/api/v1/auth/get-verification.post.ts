import RedisClient from '~/server/utils/redisClient'
import Mailer from '~/server/utils/mailer'

const redis = RedisClient.getInstance()

// 生成指定长度的随机验证码
function getRandomCode(length = 6): number {
  return Number(Array.from({ length }).map(() => Math.floor(Math.random() * 10)).join(''))
}

// 定义一个事件处理函数，用于向请求者发送验证码
export default defineEventHandler(async (event) => {
  const email = getQuery(event).email as string
  if (!email) {
    return createError({ statusCode: 400, statusMessage: 'Email is required' })
  }

  const code = getRandomCode()
  await redis.set(`verification_code:${email}`, code, 'EX', 300)

  await Mailer.sendMail({
    to: email,
    subject: 'Your verification code',
    text: `Your verification code is ${code}`,
    html: `<p>Your verification code is <strong>${code}</strong></p>`
  })

  return { success: true }
})