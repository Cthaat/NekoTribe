import { createError, setResponseHeader, type H3Event } from 'h3';
import type { Connection } from 'oracledb';
import sql from '../../../specifications/requirements/recommendation-feedback.json';
import { v2Auth, v2BadRequest, v2Body, v2Execute, v2Forbidden, v2NotFound, v2Ok, v2One, v2ServerError } from '~/server/utils/v2';

type ResourceType = keyof typeof sql.targets;

export async function v2RecommendationFeedback(event: H3Event, connection: Connection) {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const actor_id = v2Auth(event).userId;
  const body = await v2Body(event);
  const legacy = Object.hasOwn(body, 'post_id') || Object.hasOwn(body, 'feedback');
  const allowed = legacy ? ['post_id', 'feedback', 'reason'] : ['resource_type', 'resource_id', 'action', 'reason'];
  const resource_type = legacy ? 'post' : body.resource_type;
  const resource_id = legacy ? body.post_id : body.resource_id;
  const action = legacy ? body.feedback : body.action;
  if (Object.keys(body).some(key => !allowed.includes(key)) || typeof resource_type !== 'string' ||
      !Object.hasOwn(sql.targets, resource_type) || typeof resource_id !== 'number' ||
      !Number.isSafeInteger(resource_id) || resource_id <= 0 || typeof action !== 'string' ||
      !sql.actions.includes(action) || (body.reason !== undefined && typeof body.reason !== 'string')) {
    v2BadRequest('推荐反馈参数错误');
  }
  const reason = typeof body.reason === 'string' ? body.reason.trim() : '';
  if (Buffer.byteLength(reason) > 500 || reason.includes('\0')) v2BadRequest('推荐反馈参数错误');
  if (!await v2One(connection, sql.schema)) {
    throw createError({ statusCode: 503, statusMessage: 'Service temporarily unavailable',
      data: { code: 50301, message: '服务暂不可用，请稍后重试。', data: null, meta: null } });
  }
  try {
    if (!await v2One(connection, sql.lockActor, { actor_id })) v2Forbidden('账号不可用');
    const scope = resource_type === 'tag' ? { resource_id } : { resource_id, actor_id };
    if (!await v2One(connection, sql.targets[resource_type as ResourceType], scope)) v2NotFound('反馈目标不存在');
    if (await v2Execute(connection, sql.save, { actor_id, resource_type, resource_id, action, reason: reason || null }, false) !== 1) {
      v2ServerError();
    }
    await connection.commit();
  } catch (error) {
    await connection.rollback();
    throw error;
  }
  return v2Ok({ accepted: true });
}
