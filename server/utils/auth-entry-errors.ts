import { createError, isError } from 'h3';
import { v2ServerError } from './v2';
import type { V2RouteHandler } from './v2';

// Only public, fixed messages from these authentication entry points are safe
// to log. Recreate errors so an attached driver cause or stack cannot escape.
const publicMessages: Record<number, ReadonlySet<string>> = {
  400: new Set(['请求体必须是 JSON 对象', 'account 不能为空', 'email 不能为空', 'username 不能为空', 'password 不能为空', 'new_password 不能为空', 'confirm_password 不能为空', 'display_name 不能为空', 'content 不能为空', '必须同意服务条款', '两次输入的密码不一致', 'challenge_id 不能为空', 'type 不能为空', 'type 参数错误', 'channel 参数错误', 'verification_id 不能为空', 'code 不能为空', '验证码不存在或已过期', 'id 参数错误', 'name 参数错误', 'parent_comment_id 参数错误', 'notification_ids 参数错误', '双因素密钥格式错误', 'visibility 参数错误', 'language 参数错误', '附件不存在或无权使用', '引用字段只能传一个', '媒体不存在或不可用']),
  401: new Set(['账号或密码错误', '验证码错误', '双因素验证已过期，请重新登录', '双因素验证码错误', '未认证或 token 无效']),
  403: new Set(['账号不可用']),
  404: new Set(['用户不存在', '帖子不存在', '话题不存在', '通知不存在', '父评论不存在', '评论不存在']),
  409: new Set(['邮箱或用户名已被注册']),
  422: new Set(['双因素认证尚未启用', '请先完成验证码校验', '只能删除自己的评论', '只能删除自己的帖子', '只能修改自己的帖子']),
  500: new Set(['服务器内部错误']),
  501: new Set(['短信验证码暂不可用']),
  503: new Set(['服务暂不可用，请稍后重试。'])
};

function sanitizedPublicError(error: unknown): ReturnType<typeof createError> | null {
  if (!isError(error)) return null;
  // H3's JSON parser emits a fixed 400 without the v2 envelope.
  if (error.statusCode === 400 && error.message === 'Invalid JSON body' && error.data === undefined) {
    return createError({statusCode: 400, statusMessage: 'Bad Request', message: 'Invalid JSON body'});
  }
  const data = error.data as V2Response<null> | undefined;
  const message = data?.message;
  if (typeof message !== 'string' || !publicMessages[error.statusCode]?.has(message) ||
      data?.code !== error.statusCode * 100 + 1 || data.data !== null || data.meta !== null ||
      (error.statusCode === 503 ? error.message !== 'Service temporarily unavailable' : error.message !== message)) return null;
  return createError({
    statusCode: error.statusCode,
    ...(error.statusCode === 503 ? {statusMessage: 'Service temporarily unavailable'} : {message}),
    data: {code: data.code, message, data: null, meta: null}
  });
}

export function safeAuthEntry<T>(handler: V2RouteHandler<T>): V2RouteHandler<T> {
  return async (event, connection) => {
    try {
      return await handler(event, connection);
    } catch (error) {
      // Driver exceptions can expose unexpected getters or proxy objects.
      let sanitized: ReturnType<typeof createError> | null;
      try { sanitized = sanitizedPublicError(error); }
      catch { v2ServerError(); }
      if (sanitized) throw sanitized;
      v2ServerError();
    }
  };
}
