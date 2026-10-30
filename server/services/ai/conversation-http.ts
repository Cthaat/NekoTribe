import { getQuery } from 'h3';
import type { H3Event } from 'h3';
import type oracledb from 'oracledb';
import { v2Auth, v2BadRequest, v2Body, v2Ok, v2RouterParam } from '~/server/utils/v2';
import { appendUserMessage, createConversation, deleteConversation, listConversations, listConversationMessages, readConversation } from './conversation-store';

export async function create(event: H3Event, connection: oracledb.Connection) {
  v2Auth(event);
  return v2Ok(await createConversation(event, connection, await v2Body(event)));
}
export async function listOwned(event: H3Event, connection: oracledb.Connection) {
  v2Auth(event);
  const query = getQuery(event);
  const after = query.after_id ?? '';
  const rawLimit = query.limit ?? '20';
  if (typeof after !== 'string' || (after !== '' && !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(after)) ||
      typeof rawLimit !== 'string' || !/^(0|[1-9][0-9]*)$/.test(rawLimit)) v2BadRequest('分页参数错误');
  const limit = Number(rawLimit);
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > 50) v2BadRequest('分页参数错误');
  return v2Ok(await listConversations(event, connection, after, limit));
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
  const body = await v2Body(event);
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
  const limit = integer(query.limit, 20, 50);
  if (limit < 1) v2BadRequest('分页参数错误');
  return v2Ok(await listConversationMessages(event, connection, v2RouterParam(event, 'id'), after, limit));
}
