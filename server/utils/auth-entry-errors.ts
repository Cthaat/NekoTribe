import { createError, isError } from 'h3';
import { v2ServerError } from './v2';
import type { V2RouteHandler } from './v2';

// Only public, fixed messages from these authentication entry points are safe
// to log. Recreate errors so an attached driver cause or stack cannot escape.
const publicMessages: Record<number, ReadonlySet<string>> = {
  400: new Set(['请求体必须是 JSON 对象', 'account 不能为空', 'email 不能为空', 'username 不能为空', 'password 不能为空', 'new_password 不能为空', 'confirm_password 不能为空', 'display_name 不能为空', 'content 不能为空', '必须同意服务条款', '两次输入的密码不一致', 'challenge_id 不能为空', 'type 不能为空', 'type 参数错误', 'channel 参数错误', 'verification_id 不能为空', 'code 不能为空', '验证码不存在或已过期', 'id 参数错误', 'name 参数错误', 'parent_comment_id 参数错误', 'notification_ids 参数错误', '双因素密钥格式错误', 'visibility 参数错误', 'language 参数错误', '附件不存在或无权使用', '引用字段只能传一个', '媒体不存在或不可用', '请使用 multipart/form-data 上传媒体文件', '上传文件为空', '媒体上传失败', '仅支持图片、视频、音频、文档、文本或压缩包文件', '文件不能超过 500MB']),
  401: new Set(['账号或密码错误', '验证码错误', '双因素验证已过期，请重新登录', '双因素验证码错误', '未认证或 token 无效']),
  403: new Set(['账号不可用', '需要群管理员权限', '需要审核权限']),
  404: new Set(['用户不存在', '帖子不存在', '话题不存在', '通知不存在', '父评论不存在', '评论不存在', '会话不存在']),
  409: new Set(['邮箱或用户名已被注册', '会话已变更，请重试']),
  422: new Set(['双因素认证尚未启用', '请先完成验证码校验', '只能删除自己的评论', '只能删除自己的帖子', '只能修改自己的帖子']),
  429: new Set(['验证码发送过于频繁，请稍后重试', '验证码尝试次数已用完，请重新获取验证码']),
  500: new Set(['服务器内部错误']),
  501: new Set(['短信验证码暂不可用', '媒体存储暂不可用']),
  503: new Set(['服务暂不可用，请稍后重试。', '媒体存储暂不可用'])
};
publicMessages[400] = new Set([...publicMessages[400]!, '会话参数错误', '会话用途错误', '群组参数错误', '会话标题错误', '会话标题过长', '消息参数错误', '消息内容错误', '分页参数错误', '写作会话上下文不可用', '知识会话上下文不可用', '知识检索参数错误']);
publicMessages[400] = new Set([...publicMessages[400]!, 'new_email 不能为空', 'profile_visibility 参数错误', '请通过双因素认证设置流程修改 two_factor_enabled', 'ai_sentiment_model_id 长度不能超过 128', 'ai_sentiment_top_k 必须在 1 到 10 之间']);
publicMessages[404] = new Set([...publicMessages[404]!, '用户设置不存在']);
publicMessages[409] = new Set([...publicMessages[409]!, '邮箱已被使用']);
publicMessages[400] = new Set([...publicMessages[400]!, 'confirmation 不能为空', '确认内容不匹配']);
publicMessages[401] = new Set([...publicMessages[401]!, '密码错误']);
publicMessages[409] = new Set([...publicMessages[409]!, '账号已变更，请重新验证']);
publicMessages[409] = new Set([...publicMessages[409]!, '双因素设置已变更，请重试']);
publicMessages[422] = new Set([...publicMessages[422]!, '双因素认证已启用，请先关闭后再重新设置', '请先生成双因素认证密钥']);
publicMessages[400] = new Set([...publicMessages[400]!, '密码至少需要6个字符', '邮箱格式错误', '用户名至少需要2个字符', '昵称至少需要2个字符']);
publicMessages[400] = new Set([...publicMessages[400]!, 'target_id 参数错误', 'expires_at 参数错误']);
publicMessages[400] = new Set([...publicMessages[400]!, '媒体替代文本或描述过长', '媒体访问范围无效']);
publicMessages[422] = new Set([...publicMessages[422]!, '不能屏蔽自己', '不能静音自己']);
publicMessages[422] = new Set([...publicMessages[422]!, '不能关注自己']);
publicMessages[403] = new Set([...publicMessages[403]!, '无法关注该用户']);
publicMessages[400] = new Set([...publicMessages[400]!, 'action 参数错误', 'appeal_message 不能为空', 'appeal_message 参数错误']);
publicMessages[404] = new Set([...publicMessages[404]!, '处置记录不存在']);
publicMessages[409] = new Set([...publicMessages[409]!, '已有待处理申诉']);
publicMessages[400] = new Set([...publicMessages[400]!, 'appeal_id 参数错误', 'appeal_status 参数错误', 'admin_response 参数错误']);
publicMessages[404] = new Set([...publicMessages[404]!, '申诉不存在']);
publicMessages[409] = new Set([...publicMessages[409]!, '申诉已处理']);

publicMessages[400] = new Set([...publicMessages[400]!, 'report_id 参数错误', 'status 参数错误']);
publicMessages[404] = new Set([...publicMessages[404]!, '举报不存在']);
publicMessages[400] = new Set([...publicMessages[400]!, 'target_type 参数错误', 'reason 参数错误', 'priority 参数错误', 'description 参数错误', 'evidence_url 参数错误']);
publicMessages[403] = new Set([...publicMessages[403]!, '不能举报自己']);
publicMessages[404] = new Set([...publicMessages[404]!, '举报目标不存在']);
publicMessages[409] = new Set([...publicMessages[409]!, '已有待处理举报']);
publicMessages[400] = new Set([...publicMessages[400]!, 'settings 参数错误']);
publicMessages[400] = new Set([...publicMessages[400]!, 'post_id 参数错误', 'post_ids 参数错误', 'note 参数错误', '请填写审核备注']);
publicMessages[403] = new Set([...publicMessages[403]!, '审核领取已关闭']);
publicMessages[409] = new Set([...publicMessages[409]!, '案件由其他审核员领取']);
publicMessages[400] = new Set([...publicMessages[400]!, 'user_id 参数错误', 'duration_hours 参数错误']);
publicMessages[403] = new Set([...publicMessages[403]!, '不能处罚自己']);
publicMessages[403] = new Set([...publicMessages[403]!, '当前账号不能发布内容']);
publicMessages[409] = new Set([...publicMessages[409]!, '账号状态不允许此处置']);
publicMessages[422] = new Set([...publicMessages[422]!, '只能查看自己帖子的统计']);
publicMessages[400] = new Set([...publicMessages[400]!, '推荐反馈参数错误']);
publicMessages[404] = new Set([...publicMessages[404]!, '反馈目标不存在']);
publicMessages[400] = new Set([...publicMessages[400]!, '群运营草稿参数错误']);
publicMessages[400] = new Set([...publicMessages[400]!, '审核建议参数错误']);
publicMessages[400] = new Set([...publicMessages[400]!, '审核反馈参数错误']);
publicMessages[400] = new Set([...publicMessages[400]!, 'comment_id 参数错误']);
publicMessages[429] = new Set([...publicMessages[429]!, 'AI 请求额度已用完，请稍后重试']);
publicMessages[403] = new Set([...publicMessages[403]!, '权限不足']);
publicMessages[400] = new Set([...publicMessages[400]!, '图片参数错误', '图片类型或大小不支持', '个人 AI 连接参数错误']);
publicMessages[404] = new Set([...publicMessages[404]!, '图片不存在', '个人 AI 连接不存在']);
publicMessages[409] = new Set([...publicMessages[409]!, '图片已关联', '个人 AI 连接已变更，请重新填写密钥']);
publicMessages[400] = new Set([...publicMessages[400]!, 'Passkey 参数错误']);
publicMessages[404] = new Set([...publicMessages[404]!, 'Passkey 不存在']);
publicMessages[409] = new Set([...publicMessages[409]!, 'Passkey 已登记', '请保留至少一种登录方式']);
publicMessages[400] = new Set([...publicMessages[400]!, 'GitHub 授权参数错误']);
publicMessages[404] = new Set([...publicMessages[404]!, 'GitHub 绑定不存在']);
publicMessages[409] = new Set([...publicMessages[409]!, 'GitHub 账号已绑定']);

export function v2ServiceUnavailable(): never {
  throw createError({
    statusCode: 503,
    statusMessage: 'Service temporarily unavailable',
    data: {code:50301,message:'服务暂不可用，请稍后重试。',data:null,meta:null},
  });
}

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
    return safeV2Action(() => handler(event, connection));
  };
}

export async function safeV2Action<T>(action: () => Promise<T>): Promise<T> {
    try {
      return await action();
    } catch (error) {
      // Driver exceptions can expose unexpected getters or proxy objects.
      let sanitized: ReturnType<typeof createError> | null;
      try { sanitized = sanitizedPublicError(error); }
      catch { v2ServerError(); }
      if (sanitized) throw sanitized;
      v2ServerError();
    }
}
