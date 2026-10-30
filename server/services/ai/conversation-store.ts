import { randomUUID } from 'node:crypto';
import type { H3Event } from 'h3';
import oracledb from 'oracledb';
import { requireFeatureSchema } from '~/server/database/readiness';
import { v2Auth, v2BadRequest, v2Conflict, v2DateString, v2Execute, v2NotFound, v2Number, v2One, v2ServerError, v2String } from '~/server/utils/v2';
import { authorizeConversationScope, type ConversationPurpose } from './conversation-access';

export interface ConversationRecord {
  conversation_id: string;
  purpose: ConversationPurpose;
  group_id: number | null;
  title: string | null;
  created_at: string;
  updated_at: string;
}
export interface ConversationMessageRecord {
  message_id: string;
  conversation_id: string;
  sequence_no: number;
  role: string;
  content: string;
  model_id: string | null;
  model_version: string | null;
  config_revision: number | null;
  created_at: string;
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

/** Internal bounded history read. Rechecks permission before exposing fetched content. */
export async function listConversationMessages(
  event: H3Event,
  connection: oracledb.Connection,
  id: string,
  afterSequence: number,
  limit: number
): Promise<ConversationMessageRecord[]> {
  return readMessages(event, connection, id, afterSequence, limit, false);
}
/** Internal context read: fetch only the newest bounded page, returned oldest first. */
export async function listRecentConversationMessages(event: H3Event, connection: oracledb.Connection, id: string): Promise<ConversationMessageRecord[]> {
  return readMessages(event, connection, id, 0, 50, true);
}
async function readMessages(
  event: H3Event, connection: oracledb.Connection, id: string, afterSequence: number, limit: number, newest: boolean
): Promise<ConversationMessageRecord[]> {
  const actor = v2Auth(event);
  if (!Number.isSafeInteger(afterSequence) || afterSequence < 0 || afterSequence > 9999999999 ||
      !Number.isSafeInteger(limit) || limit < 1 || limit > 50) v2BadRequest('分页参数错误');
  await readConversation(event, connection, id);
  const result = await connection.execute<Record<string, unknown>>(
    `SELECT m.message_id,m.conversation_id,m.sequence_no,m.role,m.content,m.model_id,m.model_version,m.config_revision,m.created_at
       FROM n_ai_messages m JOIN n_ai_conversations c ON c.conversation_id=m.conversation_id
       WHERE m.conversation_id=:conversation_id AND c.owner_user_id=:owner_user_id AND m.sequence_no>:after_sequence
       ORDER BY m.sequence_no ${newest ? 'DESC' : 'ASC'} FETCH FIRST :row_limit ROWS ONLY`,
    { conversation_id: id, owner_user_id: actor.userId, after_sequence: afterSequence, row_limit: limit },
    { outFormat: oracledb.OUT_FORMAT_OBJECT, fetchTypeHandler: metadata =>
      metadata.name === 'CONTENT' ? { type: oracledb.STRING } : undefined }
  );
  await readConversation(event, connection, id);
  const messages = (result.rows ?? []).map(row => {
    if (typeof row.CONTENT !== 'string') v2ServerError();
    return {
      message_id: v2String(row.MESSAGE_ID),
      conversation_id: v2String(row.CONVERSATION_ID),
      sequence_no: v2Number(row.SEQUENCE_NO),
      role: v2String(row.ROLE),
      content: row.CONTENT,
      model_id: row.MODEL_ID === null || row.MODEL_ID === undefined ? null : v2String(row.MODEL_ID),
      model_version: row.MODEL_VERSION === null || row.MODEL_VERSION === undefined ? null : v2String(row.MODEL_VERSION),
      config_revision: row.CONFIG_REVISION === null || row.CONFIG_REVISION === undefined ? null : v2Number(row.CONFIG_REVISION),
      created_at: v2DateString(row.CREATED_AT) || ''
    };
  });
  return newest ? messages.reverse() : messages;
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
  return appendMessage(event, connection, id, { role: 'user', content });
}

/** Trusted internal caller only. The client cannot select assistant role or model metadata. */
export async function appendAssistantMessage(
  event: H3Event,
  connection: oracledb.Connection,
  id: string,
  input: { content: string; expectedSequence: number; modelId: string; configRevision: number }
): Promise<{ message_id: string; conversation_id: string; sequence_no: number; role: 'assistant' }> {
  if (!Number.isSafeInteger(input.expectedSequence) || input.expectedSequence < 1 ||
      input.expectedSequence >= 9999999999 || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(input.modelId) ||
      !Number.isSafeInteger(input.configRevision) || input.configRevision < 1 || input.configRevision > 999999999999999) {
    v2BadRequest('模型回复参数错误');
  }
  return appendMessage(event, connection, id, { role: 'assistant', ...input });
}

type AppendInput = { role: 'user'; content: unknown } |
  { role: 'assistant'; content: string; expectedSequence: number; modelId: string; configRevision: number };
async function appendMessage<T extends AppendInput>(
  event: H3Event, connection: oracledb.Connection, id: string, input: T
): Promise<{ message_id: string; conversation_id: string; sequence_no: number; role: T['role'] }> {
  const actor = v2Auth(event);
  if (!validId(id)) v2NotFound('会话不存在');
  const content = input.content;
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
    if (input.role === 'assistant' && sequenceNo !== input.expectedSequence + 1) v2Conflict('会话已变更，请重试');
    const messageId = randomUUID();
    const inserted = await v2Execute(connection, `INSERT INTO n_ai_messages
      (message_id,conversation_id,sequence_no,role,content,model_id,config_revision)
      VALUES (:message_id,:conversation_id,:sequence_no,:role,:content,:model_id,:config_revision)`,
      { message_id: messageId, conversation_id: id, sequence_no: sequenceNo, role: input.role, content,
        model_id: input.role === 'assistant' ? input.modelId : null,
        config_revision: input.role === 'assistant' ? input.configRevision : null }, false);
    if (inserted !== 1) v2ServerError();
    const updated = await v2Execute(connection, `UPDATE n_ai_conversations SET updated_at=CURRENT_TIMESTAMP
      WHERE conversation_id=:conversation_id AND owner_user_id=:owner_user_id`,
      { conversation_id: id, owner_user_id: actor.userId }, false);
    if (updated !== 1) v2ServerError();
    await authorizeConversationScope(event, connection, { ownerUserId: actor.userId, purpose: scope.purpose, groupId: scope.group_id });
    commitStarted = true;
    await connection.commit();
    return { message_id: messageId, conversation_id: id, sequence_no: sequenceNo, role: input.role };
  } catch (error) {
    if (commitStarted) v2ServerError();
    try { await connection.rollback(); } catch { v2ServerError(); }
    throw error;
  }
}
