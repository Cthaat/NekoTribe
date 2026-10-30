import { randomUUID } from 'node:crypto';
import type { H3Event } from 'h3';
import type oracledb from 'oracledb';
import { requireFeatureSchema } from '~/server/database/readiness';
import { v2Auth, v2BadRequest, v2DateString, v2Execute, v2NotFound, v2Number, v2One, v2ServerError, v2String } from '~/server/utils/v2';
import { authorizeConversationScope, type ConversationPurpose } from './conversation-access';

export interface ConversationRecord {
  conversation_id: string;
  purpose: ConversationPurpose;
  group_id: number | null;
  title: string | null;
  created_at: string;
  updated_at: string;
}

function validId(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function mapRow(row: Record<string, unknown>): ConversationRecord {
  return {
    conversation_id: v2String(row.CONVERSATION_ID),
    purpose: v2String(row.PURPOSE) as ConversationPurpose,
    group_id: row.GROUP_ID === null || row.GROUP_ID === undefined ? null : v2Number(row.GROUP_ID),
    title: row.TITLE === null || row.TITLE === undefined ? null : v2String(row.TITLE),
    created_at: v2DateString(row.CREATED_AT) || '',
    updated_at: v2DateString(row.UPDATED_AT) || ''
  };
}

export async function readConversation(event: H3Event, connection: oracledb.Connection, id: string): Promise<ConversationRecord> {
  const actor = v2Auth(event);
  if (!validId(id)) v2NotFound('会话不存在');
  await requireFeatureSchema(connection, 'ai-conversations');
  const row = await v2One(connection, `SELECT conversation_id,owner_user_id,purpose,group_id,title,created_at,updated_at
    FROM n_ai_conversations WHERE conversation_id=:conversation_id AND owner_user_id=:owner_user_id`,
    { conversation_id: id, owner_user_id: actor.userId });
  if (!row) v2NotFound('会话不存在');
  const record = mapRow(row);
  await authorizeConversationScope(event, connection, { ownerUserId: v2Number(row.OWNER_USER_ID), purpose: record.purpose, groupId: record.group_id });
  return record;
}

export async function createConversation(event: H3Event, connection: oracledb.Connection, input: unknown): Promise<ConversationRecord> {
  const actor = v2Auth(event);
  if (!input || typeof input !== 'object' || Array.isArray(input)) v2BadRequest('会话参数错误');
  const body = input as Record<string, unknown>;
  if (Object.keys(body).some(key => !['purpose', 'group_id', 'title'].includes(key))) v2BadRequest('会话参数错误');
  const purpose = body.purpose;
  if (typeof purpose !== 'string' || !['knowledge', 'writing', 'group', 'moderation'].includes(purpose)) v2BadRequest('会话用途错误');
  const groupId = body.group_id === undefined || body.group_id === null ? null : body.group_id;
  if (groupId !== null && (typeof groupId !== 'number' || !Number.isSafeInteger(groupId) || groupId <= 0)) v2BadRequest('群组参数错误');
  if (body.title !== undefined && body.title !== null && typeof body.title !== 'string') v2BadRequest('会话标题错误');
  const title = typeof body.title === 'string' ? body.title.trim() : '';
  if (title.length > 200) v2BadRequest('会话标题过长');
  await authorizeConversationScope(event, connection, { ownerUserId: actor.userId, purpose: purpose as ConversationPurpose, groupId });
  await requireFeatureSchema(connection, 'ai-conversations');
  const id = randomUUID();
  let commitStarted = false;
  try {
    const inserted = await v2Execute(connection, `INSERT INTO n_ai_conversations (conversation_id,owner_user_id,purpose,group_id,title)
      VALUES (:conversation_id,:owner_user_id,:purpose,:group_id,:title)`,
      { conversation_id: id, owner_user_id: actor.userId, purpose, group_id: groupId, title: title || null }, false);
    if (inserted !== 1) v2ServerError();
    const result = await readConversation(event, connection, id);
    commitStarted = true;
    await connection.commit();
    return result;
  } catch (error) {
    if (commitStarted) v2ServerError();
    try { await connection.rollback(); } catch { v2ServerError(); }
    throw error;
  }
}

/** Internal entry point for a user turn; model/tool turns must use their own trusted path. */
export async function appendUserMessage(
  event: H3Event,
  connection: oracledb.Connection,
  id: string,
  content: unknown
): Promise<{ message_id: string; conversation_id: string; sequence_no: number; role: 'user' }> {
  const actor = v2Auth(event);
  if (!validId(id)) v2NotFound('会话不存在');
  if (typeof content !== 'string' || content.length === 0 || Buffer.byteLength(content, 'utf8') > 65536) {
    v2BadRequest('消息内容错误');
  }
  await requireFeatureSchema(connection, 'ai-conversations');
  let commitStarted = false;
  try {
    const row = await v2One(connection, `SELECT conversation_id,owner_user_id,purpose,group_id,title,created_at,updated_at
      FROM n_ai_conversations WHERE conversation_id=:conversation_id AND owner_user_id=:owner_user_id FOR UPDATE`,
      { conversation_id: id, owner_user_id: actor.userId });
    if (!row) v2NotFound('会话不存在');
    const scope = mapRow(row);
    await authorizeConversationScope(event, connection, { ownerUserId: v2Number(row.OWNER_USER_ID), purpose: scope.purpose, groupId: scope.group_id });
    const next = await v2One(connection, 'SELECT NVL(MAX(sequence_no),0)+1 AS next_sequence FROM n_ai_messages WHERE conversation_id=:conversation_id', { conversation_id: id });
    const sequenceNo = v2Number(next?.NEXT_SEQUENCE);
    if (!Number.isSafeInteger(sequenceNo) || sequenceNo <= 0 || sequenceNo > 9999999999) v2ServerError();
    const messageId = randomUUID();
    const inserted = await v2Execute(connection, `INSERT INTO n_ai_messages
      (message_id,conversation_id,sequence_no,role,content)
      VALUES (:message_id,:conversation_id,:sequence_no,'user',:content)`,
      { message_id: messageId, conversation_id: id, sequence_no: sequenceNo, content }, false);
    if (inserted !== 1) v2ServerError();
    const updated = await v2Execute(connection, `UPDATE n_ai_conversations SET updated_at=CURRENT_TIMESTAMP
      WHERE conversation_id=:conversation_id AND owner_user_id=:owner_user_id`,
      { conversation_id: id, owner_user_id: actor.userId }, false);
    if (updated !== 1) v2ServerError();
    await authorizeConversationScope(event, connection, { ownerUserId: actor.userId, purpose: scope.purpose, groupId: scope.group_id });
    commitStarted = true;
    await connection.commit();
    return { message_id: messageId, conversation_id: id, sequence_no: sequenceNo, role: 'user' };
  } catch (error) {
    if (commitStarted) v2ServerError();
    try { await connection.rollback(); } catch { v2ServerError(); }
    throw error;
  }
}
