import bcrypt from 'bcrypt';
import { verifyCode } from '~/server/utils/auth/verifyCode';

export default defineEventHandler(async (event): Promise<RegisterResponse> => {
  const body = await readBody<registerPayload>(event)
  if (!body) {
    throw createError({
      statusCode: 400,
      message: '请求体不能为空',
      statusMessage: 'Bad Request',
      data: {
        success: false,
        message: '请求体不能为空',
        code: 400,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  }

  if(!body.email) {
    throw createError({
      statusCode: 400,
      message: '邮箱地址不能为空',
      statusMessage: 'Bad Request',
      data: {
        success: false,
        message: '邮箱地址不能为空',
        code: 400,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  }

  if(!/^\S+@\S+\.\S+$/.test(body.email)) {
    throw createError({
      statusCode: 400,
      message: '邮箱地址格式不正确',
      statusMessage: 'Bad Request',
      data: {
        success: false,
        message: '邮箱地址格式不正确',
        code: 400,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  }

  if(!body.password) {
    throw createError({
      statusCode: 400,
      message: '密码不能为空',
      statusMessage: 'Bad Request',
      data: {
        success: false,
        message: '密码不能为空',
        code: 400,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  }

  if(body.password.length < 6) {
    throw createError({
      statusCode: 400,
      message: '密码长度不能少于6个字符',
      statusMessage: 'Bad Request',
      data: {
        success: false,
        message: '密码长度不能少于6个字符',
        code: 400,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  }

  if (body.password !== body.confirmPassword) {
    throw createError({
      statusCode: 400,
      message: '密码和确认密码不匹配',
      statusMessage: 'Bad Request',
      data: {
        success: false,
        message: '密码和确认密码不匹配',
        code: 400,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  }

  if (!body.agreeToTerms) {
    throw createError({
      statusCode: 400,
      message: '必须同意服务条款',
      statusMessage: 'Bad Request',
      data: {
        success: false,
        message: '必须同意服务条款',
        code: 400,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  }

  if (!body.captcha) {
    throw createError({
      statusCode: 400,
      message: '验证码不能为空',
      statusMessage: 'Bad Request',
      data: {
        success: false,
        message: '验证码不能为空',
        code: 400,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  }

  await verifyCode(body.email, body.captcha);

  const hashedPassword: string = await bcrypt.hash(body.password, 10);

  // TODO: 返回成功
  // 这里应该添加实际的注册逻辑


  // 暂时返回一个成功响应
  return {
    success: true,
    message: '注册成功',
    data: {},
    code: 200,
    timestamp: new Date().toISOString()
  } as RegisterResponse;
});