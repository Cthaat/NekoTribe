import { getQuery } from 'h3';
import type { H3Event } from 'h3';
import type oracledb from 'oracledb';
import { v2Auth, v2BadRequest, v2Body, v2Ok, v2RouterParam } from '~/server/utils/v2';
import { appendUserMessage, createConversation, listConversationMessages, readConversation } from './conversation-store';

export async function create(event: H3Event, connection: oracledb.Connection) {
  v2Auth(event);
  return v2Ok(await createConversation(event, connection, await v2Body(event)));
}
export async function read(event: H3Event, connection: oracledb.Connection) {
  v2Auth(event);
  return v2Ok(await readConversation(event, connection, v2RouterParam(event, 'id')));
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
