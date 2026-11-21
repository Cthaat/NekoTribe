import { getQuery } from 'h3';
import type { H3Event } from 'h3';
import type oracledb from 'oracledb';
import { v2Auth, v2BadRequest, v2Ok, v2Record, v2RouterParam } from '~/server/utils/v2';
import { readBoundedBody } from '../../utils/bounded-body';
import { appendUserMessage, createConversation, deleteConversation, listConversations, listConversationMessages, readConversation } from './conversation-store';
import { hasTooManyAiBodyMembers } from './knowledge-search-body';

async function readConversationBody(event: H3Event): Promise<Record<string, unknown>> {
  let value: unknown;
  let text: string;
  try {
    const bytes = await readBoundedBody(event.node.req, 1024 * 1024);
    text = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes);
    value = JSON.parse(text);
  } catch {
    v2BadRequest('请求体必须是 JSON 对象');
  }
  const body = v2Record(value);
  if (hasTooManyAiBodyMembers(text, Object.keys(body).length) ||
      Object.values(body).some(value => typeof value === 'string' && !value.isWellFormed())) {
    v2BadRequest('请求体必须是 JSON 对象');
  }
  return body;
}

export async function create(event: H3Event, connection: oracledb.Connection) {
  v2Auth(event);
  return v2Ok(await createConversation(event, connection, await readConversationBody(event)));
}
export async function listOwned(event: H3Event, connection: oracledb.Connection) {
  v2Auth(event);
  const query = getQuery(event);
  const after = query.after_id ?? '';
  const rawLimit = query.limit ?? '20';
  const purpose = query.purpose;
  if (purpose !== undefined && purpose !== 'knowledge' && purpose !== 'writing' &&
      purpose !== 'group' && purpose !== 'moderation') v2BadRequest('会话用途错误');
  const rawGroup = query.group_id;
  let groupId: number | undefined;
  if (rawGroup !== undefined) {
    if (purpose !== 'group' || typeof rawGroup !== 'string' || rawGroup.trim() !== rawGroup ||
        !/^[1-9][0-9]{0,15}$/.test(rawGroup) || !Number.isSafeInteger(Number(rawGroup))) v2BadRequest('群组参数错误');
    groupId = Number(rawGroup);
  }
  const kind = query.target_type;
  const rawTargetId = query.target_id;
  let targetTitle: string | undefined;
  if (kind !== undefined || rawTargetId !== undefined) {
    if (purpose !== 'moderation' ||
        (kind !== 'post' && kind !== 'comment' && kind !== 'group_post' && kind !== 'group_post_comment') ||
        typeof rawTargetId !== 'string' || rawTargetId.trim() !== rawTargetId ||
        !/^[1-9][0-9]{0,14}$/.test(rawTargetId)) v2BadRequest('审核对象错误');
    targetTitle = `moderation:${kind}:${rawTargetId}`;
  }
  if (typeof after !== 'string' || (after !== '' && !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(after)) ||
      typeof rawLimit !== 'string' || !/^(0|[1-9][0-9]*)$/.test(rawLimit)) v2BadRequest('分页参数错误');
  const limit = Number(rawLimit);
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > 50) v2BadRequest('分页参数错误');
  return v2Ok(await listConversations(event, connection, after, limit, purpose, groupId, targetTitle));
}
export async function read(event: H3Event, connection: oracledb.Connection) {
  v2Auth(event);
  return v2Ok(await readConversation(event, connection, v2RouterParam(event, 'id')));
}
export async function remove(event: H3Event, connection: oracledb.Connection) {
  v2Auth(event);
  await deleteConversation(event, connection, v2RouterParam(event, 'id'));
  return v2Ok(null);
}
export async function append(event: H3Event, connection: oracledb.Connection) {
  v2Auth(event);
  const body = await readConversationBody(event);
  if (Object.keys(body).length !== 1 || !Object.hasOwn(body, 'content')) v2BadRequest('消息参数错误');
  return v2Ok(await appendUserMessage(event, connection, v2RouterParam(event, 'id'), body.content));
}
export async function list(event: H3Event, connection: oracledb.Connection) {
  v2Auth(event);
  const query = getQuery(event);
  function integer(value: unknown, fallback: number, max: number): number {
    if (value === undefined) return fallback;
    if (typeof value !== 'string' || !/^(0|[1-9][0-9]*)$/.test(value)) v2BadRequest('分页参数错误');
    const number = Number(value);
    if (!Number.isSafeInteger(number) || number > max) v2BadRequest('分页参数错误');
    return number;
  }
  const after = integer(query.after_sequence, 0, 9999999999);
  const before = integer(query.before_sequence, 0, 10000000000);
  const limit = integer(query.limit, 20, 50);
  if (limit < 1 || (query.before_sequence !== undefined && (before === 0 || query.after_sequence !== undefined))) {
    v2BadRequest('分页参数错误');
  }
  return v2Ok(await listConversationMessages(event, connection, v2RouterParam(event, 'id'), after, limit, before));
}
