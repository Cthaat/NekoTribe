import bcrypt from 'bcrypt';
import jwt from 'jsonwebtoken';
import crypto from 'crypto';

const getRandomCode: GetRandomCode = (length = 6) => {
  return Number(Array.from({ length }).map(() => Math.floor(Math.random() * 10)).join(''))
}

// 事件处理函数：处理获取邮箱验证码的请求
export default defineEventHandler(async (event) => {
  const body = await readBody<GetVerificationPayload>(event)
  
})