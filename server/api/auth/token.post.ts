// server/api/auth/token.post.ts
import { generateToken, type UserPayload } from '../../utils/jwt'

export default defineEventHandler(async (event) => {
  const body = await readBody(event)
  
  const { username, email, userId, password } = body

  // 这里应该验证用户凭据（用户名/密码）
  // 为了演示，我们跳过真实的认证逻辑
  if (!username || !userId) {
    throw createError({
      statusCode: 400,
      statusMessage: '缺少必要的用户信息'
    })
  }

  // 模拟用户验证（在实际应用中，你需要查询数据库验证用户）
  const user: UserPayload = {
    userId,
    username,
    email: email || `${username}@example.com`,
    roles: ['user'] // 可以根据用户类型设置不同角色
  }

  // 生成 JWT Token
  const token = generateToken(user)

  return {
    success: true,
    token,
    user: {
      userId: user.userId,
      username: user.username,
      email: user.email
    }
  }
})
