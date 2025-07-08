import jwt from 'jsonwebtoken'
import { getRequestURL } from 'h3'

const runtimeConfig = useRuntimeConfig();

const WHITE_LIST = [
  '/api/v1/auth/'
  // 可以继续添加其他前缀
]

export default defineEventHandler((event) => {
  const url = getRequestURL(event).pathname

  // 判断是否命中白名单前缀
  if (WHITE_LIST.some(prefix => url.startsWith(prefix))) {
    return
  }

  const token = getCookie(event, 'access_token')
  if (!token) {
    throw createError({
      statusCode: 401,
      statusMessage: '未登录',
      data: {
        success: false,
        message: '请先登录',
        code: 401,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    })
  }
  try {
    const payload = jwt.verify(token, runtimeConfig.accessSecret)
    event.context.auth = payload
  } catch (err) {
    throw createError({
      statusCode: 401,
      statusMessage: 'Token无效',
      data: {
        success: false,
        message: 'Token无效或已过期',
        code: 401,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    })
  }
})