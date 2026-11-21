import { randomUUID } from 'node:crypto';
import { validAiModelVersion } from './model-configuration';
import type { H3Event } from 'h3';
import oracledb from 'oracledb';
import { requireFeatureSchema } from '~/server/database/readiness';
import { v2Auth, v2BadRequest, v2Conflict, v2DateString, v2Execute, v2NotFound, v2Number, v2One, v2ServerError, v2String } from '~/server/utils/v2';
import { authorizeConversationScope, type ConversationPurpose } from './conversation-access';
import { hydrateKnowledgeSources, type IndexedSource } from './knowledge-source';
import { encodeKnowledgeMessage, KnowledgeHistoryError, restoreKnowledgeMessage } from './knowledge-history';
import {selectKnowledgeContext, type HistoryMessage} from './knowledge-context';
import {lockSkillRegistry} from './skill-config-store';
import {decodeGroupDraft, recheckGroupDraft, requireCurrentGroupDraft, type GroupDraftRecord} from './group-draft-record';
import {currentModerationAdvice, decodeModerationAdvice, requireCurrentModerationAdvice, type ModerationAdviceRecord} from './moderation-advice-record';
import { feedbackSql, feedbackTablePresent, feedbackUnavailable, readModerationRating, type ModerationRating } from './moderation-feedback';

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
  citations?: import('./knowledge-history').RestoredCitation[];
  group_sources?: Array<{kind:'post'|'comment'; source_id:number; post_id:number}>;
  group_tools?: string[];
  moderation_advice?: Awaited<ReturnType<typeof currentModerationAdvice>>;
  moderation_feedback?: ModerationRating;
}
export interface ConversationPage {
  items: ConversationRecord[];
  next_cursor: string | null;
}

export function validId(value: string): boolean {
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

function forbidden(error: unknown): boolean {
  return typeof error === 'object' && error !== null && 'statusCode' in error && error.statusCode === 403;
}

/** List owned, currently authorized conversations without exposing inaccessible cursor IDs. */
export async function listConversations(event: H3Event, connection: oracledb.Connection, after: string, limit: number, purpose?: ConversationPurpose, groupId?: number, targetTitle?: string): Promise<ConversationPage> {
  const actor = v2Auth(event);
  if ((after !== '' && !validId(after)) || !Number.isSafeInteger(limit) || limit < 1 || limit > 50) v2BadRequest('分页参数错误');
  if (groupId !== undefined && (purpose !== 'group' || !Number.isSafeInteger(groupId) || groupId < 1)) v2BadRequest('群组参数错误');
  if (targetTitle !== undefined && purpose !== 'moderation') v2BadRequest('审核对象错误');
  await requireFeatureSchema(connection, 'ai-conversations');
  let moderationAllowed = 1;
  try {
    await authorizeConversationScope(event, connection, {ownerUserId: actor.userId, purpose: 'moderation', groupId: null});
  } catch (error) {
    if (!forbidden(error)) throw error;
    moderationAllowed = 0;
  }
  const items: ConversationRecord[] = [];
  let scanAfter = after.toLowerCase();
  for (let batch = 0; batch < 10; batch++) {
    const result = await connection.execute<Record<string, unknown>>(
      `SELECT c.conversation_id,c.owner_user_id,c.purpose,c.group_id,c.title,c.created_at,c.updated_at
       FROM n_ai_conversations c WHERE c.owner_user_id=:owner_user_id
       AND (:after_id IS NULL OR c.conversation_id>:after_id)
       AND (:purpose IS NULL OR c.purpose=:purpose)
       AND (:group_id IS NULL OR c.group_id=:group_id)
       AND (:target_title IS NULL OR (c.title=:target_title AND c.group_id IS NULL))
       AND (c.purpose IN ('knowledge','writing') OR
            (c.purpose='group' AND fn_has_group_permission(:owner_user_id,c.group_id,'admin')=1) OR
            (c.purpose='moderation' AND :moderation_allowed=1))
       ORDER BY c.conversation_id ASC FETCH FIRST :row_limit ROWS ONLY`,
      {owner_user_id: actor.userId, after_id: scanAfter || null, purpose: purpose ?? null, group_id: groupId ?? null, target_title: targetTitle ?? null, moderation_allowed: moderationAllowed, row_limit: limit + 1},
      {outFormat: oracledb.OUT_FORMAT_OBJECT}
    );
    const rows = result.rows ?? [];
    for (const row of rows) {
      const record = mapRow(row);
      if ((purpose && record.purpose !== purpose) || (groupId !== undefined && record.group_id !== groupId)) v2ServerError();
      if (targetTitle !== undefined && (record.title !== targetTitle || record.group_id !== null)) v2ServerError();
      if (v2Number(row.OWNER_USER_ID) !== actor.userId || !validId(record.conversation_id) || record.conversation_id <= scanAfter) v2ServerError();
      scanAfter = record.conversation_id;
      try {
        await authorizeConversationScope(event, connection, {ownerUserId: actor.userId, purpose: record.purpose, groupId: record.group_id});
      } catch (error) {
        if (forbidden(error)) continue;
        throw error;
      }
      if (items.length === limit) return {items, next_cursor: items[items.length - 1]!.conversation_id};
      items.push(record);
    }
    if (rows.length < limit + 1) return {items, next_cursor: null};
    if (items.length) return {items, next_cursor: items[items.length - 1]!.conversation_id};
  }
  v2ServerError();
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

export async function saveModerationFeedback(
  event: H3Event, connection: oracledb.Connection, id: string, messageId: string, rating: ModerationRating,
) {
  const actor = v2Auth(event);
  if (!validId(id) || !validId(messageId)) v2NotFound('会话不存在');
  await requireFeatureSchema(connection, 'ai-conversations');
  let commitStarted = false;
  try {
    const row = await v2One(connection, feedbackSql.lock,
      {conversation_id:id, owner_user_id:actor.userId});
    if (!row) v2NotFound('会话不存在');
    const scope = {ownerUserId:actor.userId, purpose:'moderation' as const, groupId:null};
    await authorizeConversationScope(event, connection, scope);
    const rows = await connection.execute<{CONTENT:string}>(feedbackSql.message, {conversation_id:id, message_id:messageId}, {
      outFormat:oracledb.OUT_FORMAT_OBJECT,
      fetchTypeHandler: metadata => metadata.name === 'CONTENT' ? {type:oracledb.STRING} : undefined,
    });
    const content = rows.rows?.[0]?.CONTENT;
    if (typeof content !== 'string') v2NotFound('会话不存在');
    const advice = decodeModerationAdvice(content);
    if (!advice) v2Conflict('会话已变更，请重试');
    await requireCurrentModerationAdvice(event, connection, advice, true);
    if (!await feedbackTablePresent(connection)) feedbackUnavailable();
    const affected = await v2Execute(connection, feedbackSql.save, {message_id:messageId, rating}, false);
    if (affected !== 0 && affected !== 1) feedbackUnavailable();
    await authorizeConversationScope(event, connection, scope);
    await requireCurrentModerationAdvice(event, connection, advice);
    commitStarted = true;
    await connection.commit();
    return {message_id:messageId, rating};
  } catch (error) {
    if (commitStarted) feedbackUnavailable();
    try { await connection.rollback(); } catch { feedbackUnavailable(); }
    if (typeof error === 'object' && error !== null && 'statusCode' in error &&
        (error.statusCode === 403 || error.statusCode === 404 || error.statusCode === 409)) throw error;
    feedbackUnavailable();
  }
}

/** Delete the owned conversation and its cascading messages under the same access policy. */
export async function deleteConversation(event: H3Event, connection: oracledb.Connection, id: string): Promise<void> {
  const actor = v2Auth(event);
  if (!validId(id)) v2NotFound('会话不存在');
  await requireFeatureSchema(connection, 'ai-conversations');
  let commitStarted = false;
  try {
    const row = await v2One(connection, `SELECT conversation_id,owner_user_id,purpose,group_id,title,created_at,updated_at
      FROM n_ai_conversations WHERE conversation_id=:conversation_id AND owner_user_id=:owner_user_id FOR UPDATE`,
      { conversation_id: id, owner_user_id: actor.userId });
    if (!row) v2NotFound('会话不存在');
    const record = mapRow(row);
    const scope = { ownerUserId: v2Number(row.OWNER_USER_ID), purpose: record.purpose, groupId: record.group_id };
    await authorizeConversationScope(event, connection, scope);
    const deleted = await v2Execute(connection, `DELETE FROM n_ai_conversations
      WHERE conversation_id=:conversation_id AND owner_user_id=:owner_user_id`,
      { conversation_id: id, owner_user_id: actor.userId }, false);
    if (deleted !== 1) v2ServerError();
    await authorizeConversationScope(event, connection, scope);
    commitStarted = true;
    await connection.commit();
  } catch (error) {
    if (commitStarted) v2ServerError();
    try { await connection.rollback(); } catch { v2ServerError(); }
    throw error;
  }
}

/** Internal bounded history read. Rechecks permission before exposing fetched content. */
export async function listConversationMessages(
  event: H3Event,
  connection: oracledb.Connection,
  id: string,
  afterSequence: number,
  limit: number,
  beforeSequence = 0
): Promise<ConversationMessageRecord[]> {
  return readMessages(event, connection, id, afterSequence, limit, false, beforeSequence);
}
/** Internal context read: fetch only the newest bounded page, returned oldest first. */
export async function listRecentConversationMessages(event: H3Event, connection: oracledb.Connection, id: string): Promise<ConversationMessageRecord[]> {
  return readMessages(event, connection, id, 0, 50, true);
}
async function readMessages(
  event: H3Event, connection: oracledb.Connection, id: string, afterSequence: number, limit: number, newest: boolean,
  beforeSequence = 0
): Promise<ConversationMessageRecord[]> {
  const actor = v2Auth(event);
  if (!Number.isSafeInteger(afterSequence) || afterSequence < 0 || afterSequence > 9999999999 ||
      !Number.isSafeInteger(beforeSequence) || beforeSequence < 0 || beforeSequence > 10000000000 ||
      (beforeSequence > 0 && (afterSequence > 0 || newest)) ||
      !Number.isSafeInteger(limit) || limit < 1 || limit > 50) v2BadRequest('分页参数错误');
  const conversation=await readConversation(event, connection, id);
  const backwards = beforeSequence > 0;
  const windowSql = `SELECT m.message_id,m.conversation_id,m.sequence_no,m.role,m.content,m.model_id,m.model_version,m.config_revision,m.created_at
       FROM n_ai_messages m JOIN n_ai_conversations c ON c.conversation_id=m.conversation_id
       WHERE m.conversation_id=:conversation_id AND c.owner_user_id=:owner_user_id
         AND m.sequence_no${backwards ? '<:before_sequence' : '>:after_sequence'}
       ORDER BY m.sequence_no ${backwards || newest ? 'DESC' : 'ASC'} FETCH FIRST :row_limit ROWS ONLY`;
  const result = await connection.execute<Record<string, unknown>>(
    backwards ? `SELECT * FROM (${windowSql}) ORDER BY sequence_no ASC` : windowSql,
    { conversation_id: id, owner_user_id: actor.userId, row_limit: limit,
      ...(backwards ? { before_sequence: beforeSequence } : { after_sequence: afterSequence }) },
    { outFormat: oracledb.OUT_FORMAT_OBJECT, fetchTypeHandler: metadata =>
      metadata.name === 'CONTENT' ? { type: oracledb.STRING } : undefined }
  );
  await readConversation(event, connection, id);
  const messages:ConversationMessageRecord[] = [];
  let hasFeedback: boolean | undefined;
  for (const row of result.rows ?? []) {
    if (typeof row.CONTENT !== 'string') v2ServerError();
    const message:ConversationMessageRecord={
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
    if(conversation.purpose==='knowledge' && message.role==='tool') v2ServerError();
    if(conversation.purpose==='knowledge' && message.role==='assistant') {
      try {
        const restored=await restoreKnowledgeMessage(message.content,refs=>hydrateKnowledgeSources(event,connection,refs));
        message.content=restored.answer;
        message.citations=restored.citations;
      } catch (error) {
        if (!(error instanceof KnowledgeHistoryError)) v2ServerError();
        // For model context the rows are newest first. Keep only the contiguous newer suffix.
        if (newest) break;
        message.content='公开资料已变更，历史回答不可用。';
      }
    }
    if (conversation.purpose === 'group' && message.role === 'assistant') {
      const draft = decodeGroupDraft(message.content);
      let current = null;
      if (draft && conversation.group_id !== null) {
        try { current = await recheckGroupDraft(event, connection, conversation.group_id, draft); }
        catch (error) { if (!forbidden(error)) throw error; }
      }
      message.content = current && draft ? draft.draft : '资料已变更，历史草稿不可用。';
      message.group_sources = current?.examples.map(({kind, source_id, post_id}) => ({kind, source_id, post_id})) ?? [];
      if (current && draft?.tools_used) message.group_tools = draft.tools_used;
    }
    if (conversation.purpose === 'moderation' && message.role === 'assistant') {
      const record = decodeModerationAdvice(message.content);
      let advice: Awaited<ReturnType<typeof currentModerationAdvice>> = null;
      if (record) {
        try { advice = await currentModerationAdvice(event, connection, record); }
        catch (error) {
          if (!(error instanceof Error && error.message === 'TERMS_AUTHORITY_UNAVAILABLE')) throw error;
        }
      }
      message.content = advice?.reason ?? '公开资料已变更，历史审核建议不可用。';
      message.moderation_advice = advice;
      if (advice) {
        hasFeedback ??= await feedbackTablePresent(connection);
        if (hasFeedback) {
          const rating = await readModerationRating(connection, message.message_id);
          if (rating !== undefined) message.moderation_feedback = rating;
        }
      }
    }
    messages.push(message);
  }
  if(conversation.purpose!=='writing') await readConversation(event,connection,id);
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
  input: { content: string; expectedSequence: number; modelId: string; modelVersion?: string; configRevision: number; skillGeneration:number; signal?:AbortSignal }
): Promise<{ message_id: string; conversation_id: string; sequence_no: number; role: 'assistant' }> {
  validateAssistantInput(input);
  if(!Number.isSafeInteger(input.skillGeneration) || input.skillGeneration<1 || input.skillGeneration>999_999_999_999_999) v2BadRequest('技能配置错误');
  return appendMessage(event, connection, id, { role: 'assistant', ...input });
}
function validateAssistantInput(input:{expectedSequence:number;modelId:string;modelVersion?:string;configRevision:number}, minSequence = 1):void {
  if (!Number.isSafeInteger(input.expectedSequence) || input.expectedSequence < minSequence ||
      input.expectedSequence >= 9999999999 || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(input.modelId) ||
      (input.modelVersion !== undefined && !validAiModelVersion(input.modelVersion)) ||
      !Number.isSafeInteger(input.configRevision) || input.configRevision < 1 || input.configRevision > 999999999999999) {
    v2BadRequest('模型回复参数错误');
  }
}
export async function appendGroupDraft(
  event: H3Event, connection: oracledb.Connection, id: string,
  input: { expectedSequence: number; modelId: string; modelVersion?: string; configRevision: number; draft: GroupDraftRecord; signal?: AbortSignal }
) {
  validateAssistantInput(input, 0);
  const content = JSON.stringify(input.draft);
  if (!decodeGroupDraft(content)) v2BadRequest('群运营草稿参数错误');
  return appendMessage(event, connection, id, {
    role: 'assistant', ...input, content, skillGeneration: input.draft.skill_generation,
  });
}
export async function appendModerationAdvice(
  event: H3Event, connection: oracledb.Connection, id: string,
  input: {expectedSequence:number;modelId:string;modelVersion?:string;configRevision:number;review:ModerationAdviceRecord;signal:AbortSignal},
) {
  validateAssistantInput(input,0);
  const content = JSON.stringify(input.review);
  if (!decodeModerationAdvice(content)) v2BadRequest('审核建议参数错误');
  return appendMessage(event,connection,id,{
    role:'assistant',...input,content,skillGeneration:input.review.skill_generation,
  });
}
/** Trusted knowledge generation path; references are checked inside the write transaction. */
export async function appendKnowledgeAssistantMessage(
  event:H3Event,connection:oracledb.Connection,id:string,
  input:{answer:string;sources:IndexedSource[];contextSources?:IndexedSource[];contextSnapshot?:HistoryMessage[];expectedSequence:number;modelId:string;modelVersion?:string;configRevision:number;skillGeneration:number;signal?:AbortSignal}
):Promise<{message_id:string;conversation_id:string;sequence_no:number;role:'assistant'}> {
  validateAssistantInput(input);
  if(!Number.isSafeInteger(input.skillGeneration) || input.skillGeneration<1 || input.skillGeneration>999_999_999_999_999) v2BadRequest('技能配置错误');
  let content:string;
  let contextGuard:string|undefined;
  let contextSnapshot:HistoryMessage[]|undefined;
  try {content=encodeKnowledgeMessage({answer:input.answer,sources:input.sources});} catch {v2BadRequest('知识回复参数错误');}
  try {
    if(input.contextSources!==undefined) {
      if(!Array.isArray(input.contextSources)) throw new Error('invalid context sources');
      if(input.contextSources.length) contextGuard=encodeKnowledgeMessage({answer:'context',sources:input.contextSources});
    }
    if(input.contextSnapshot!==undefined) {
      selectKnowledgeContext(input.contextSnapshot,4000000);
      contextSnapshot=input.contextSnapshot.map(message=>({sequence_no:message.sequence_no,role:message.role,content:message.content,
        ...(message.citations ? {citations:message.citations.map(source=>({...source}))} : {})}));
      const selected=selectKnowledgeContext(contextSnapshot,4000000);
      if(contextSnapshot.at(-1)?.sequence_no!==input.expectedSequence || selected.history.length!==contextSnapshot.length-1 ||
         JSON.stringify(selected.sources)!==JSON.stringify(input.contextSources ?? [])) throw new Error('invalid context snapshot');
    }
  } catch {v2BadRequest('知识回复参数错误');}
  return appendMessage(event,connection,id,{role:'assistant',content,expectedSequence:input.expectedSequence,modelId:input.modelId,modelVersion:input.modelVersion,configRevision:input.configRevision,knowledge:true,skillGeneration:input.skillGeneration,contextGuard,contextSnapshot,signal:input.signal});
}
async function checkContextSnapshot(event:H3Event,connection:oracledb.Connection,id:string,snapshot:HistoryMessage[]) {
  const messages=await listConversationMessages(event,connection,id,snapshot[0]!.sequence_no-1,snapshot.length);
  const actual=messages.map(message=>({sequence_no:message.sequence_no,role:message.role,content:message.content,
    ...(message.citations ? {citations:message.citations.map(source=>({...source}))} : {})}));
  if(JSON.stringify(actual)!==JSON.stringify(snapshot)) v2Conflict('会话已变更，请重试');
}
async function safeRestoreKnowledge(event:H3Event,connection:oracledb.Connection,content:string,lockTerms=false) {
  try {return await restoreKnowledgeMessage(content,refs=>hydrateKnowledgeSources(event,connection,refs,{lockTerms}));}
  catch {v2ServerError();}
}

type AppendInput = { role: 'user'; content: unknown } |
  { role: 'assistant'; content: string; expectedSequence: number; modelId: string; modelVersion?: string; configRevision: number; knowledge?:boolean; skillGeneration?:number; contextGuard?:string; contextSnapshot?:HistoryMessage[]; draft?:GroupDraftRecord; review?:ModerationAdviceRecord; signal?:AbortSignal };
async function appendMessage<T extends AppendInput>(
  event: H3Event, connection: oracledb.Connection, id: string, input: T
): Promise<{ message_id: string; conversation_id: string; sequence_no: number; role: T['role'] }> {
  const actor = v2Auth(event);
  if (!validId(id)) v2NotFound('会话不存在');
  const content = input.content;
  if (input.role === 'assistant') input.signal?.throwIfAborted();
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
    if(input.role==='assistant' && (scope.purpose==='knowledge')!==Boolean(input.knowledge)) v2Conflict('会话已变更，请重试');
    const groupDraft = input.role === 'assistant' ? input.draft : undefined;
    const review = input.role === 'assistant' ? input.review : undefined;
    if (input.role === 'assistant' && ((scope.purpose === 'group') !== Boolean(groupDraft))) v2Conflict('会话已变更，请重试');
    if (input.role === 'assistant' && ((scope.purpose === 'moderation') !== Boolean(review))) v2Conflict('会话已变更，请重试');
    if (groupDraft) {
      const group = await v2One(connection, 'SELECT group_id FROM n_groups WHERE group_id=:group_id FOR UPDATE', {group_id:scope.group_id});
      if (!group || scope.group_id === null) v2Conflict('会话已变更，请重试');
      await requireCurrentGroupDraft(event, connection, scope.group_id, groupDraft);
    }
    if(input.role==='assistant' && (input.knowledge || scope.purpose==='writing' || groupDraft || review)) {
      const config=await lockSkillRegistry(event,connection);
      if(config.generation!==input.skillGeneration) v2Conflict('会话已变更，请重试');
      const skillId = review ? 'moderation-advice' : groupDraft ? 'group-brief' : input.knowledge ? 'knowledge-answer' : 'writing-draft';
      await config.registry.select({actorId:actor.userId,purpose:scope.purpose,groupId:scope.group_id,skillId},async()=>{
        await authorizeConversationScope(event,connection,{ownerUserId:actor.userId,purpose:scope.purpose,groupId:scope.group_id});return true;
      });
    }
    if (review) await requireCurrentModerationAdvice(event, connection, review, true);
    if(input.role==='assistant' && input.knowledge) await safeRestoreKnowledge(event,connection,content,true);
    if(input.role==='assistant' && input.knowledge && input.contextGuard) await safeRestoreKnowledge(event,connection,input.contextGuard,true);
    const next = await v2One(connection, 'SELECT NVL(MAX(sequence_no),0)+1 AS next_sequence FROM n_ai_messages WHERE conversation_id=:conversation_id', { conversation_id: id });
    const sequenceNo = v2Number(next?.NEXT_SEQUENCE);
    if (!Number.isSafeInteger(sequenceNo) || sequenceNo <= 0 || sequenceNo > 9999999999) v2ServerError();
    if (input.role === 'assistant' && sequenceNo !== input.expectedSequence + 1) v2Conflict('会话已变更，请重试');
    if(input.role==='assistant' && input.contextSnapshot) await checkContextSnapshot(event,connection,id,input.contextSnapshot);
    const messageId = randomUUID();
    const inserted = await v2Execute(connection, `INSERT INTO n_ai_messages
      (message_id,conversation_id,sequence_no,role,content,model_id,model_version,config_revision)
      VALUES (:message_id,:conversation_id,:sequence_no,:role,:content,:model_id,:model_version,:config_revision)`,
      { message_id: messageId, conversation_id: id, sequence_no: sequenceNo, role: input.role, content,
        model_id: input.role === 'assistant' ? input.modelId : null,
        model_version: input.role === 'assistant' ? input.modelVersion ?? null : null,
        config_revision: input.role === 'assistant' ? input.configRevision : null }, false);
    if (inserted !== 1) v2ServerError();
    const updated = await v2Execute(connection, `UPDATE n_ai_conversations SET updated_at=CURRENT_TIMESTAMP
      WHERE conversation_id=:conversation_id AND owner_user_id=:owner_user_id`,
      { conversation_id: id, owner_user_id: actor.userId }, false);
    if (updated !== 1) v2ServerError();
    await authorizeConversationScope(event, connection, { ownerUserId: actor.userId, purpose: scope.purpose, groupId: scope.group_id });
    if(input.role==='assistant' && input.knowledge) await safeRestoreKnowledge(event,connection,content,true);
    if(input.role==='assistant' && input.knowledge && input.contextGuard) await safeRestoreKnowledge(event,connection,input.contextGuard,true);
    if(input.role==='assistant' && input.contextSnapshot) await checkContextSnapshot(event,connection,id,input.contextSnapshot);
    if (groupDraft && scope.group_id !== null) await requireCurrentGroupDraft(event, connection, scope.group_id, groupDraft);
    if (review) await requireCurrentModerationAdvice(event, connection, review);
    if (input.role === 'assistant') input.signal?.throwIfAborted();
    commitStarted = true;
    await connection.commit();
    return { message_id: messageId, conversation_id: id, sequence_no: sequenceNo, role: input.role };
  } catch (error) {
    if (commitStarted) v2ServerError();
    try { await connection.rollback(); } catch { v2ServerError(); }
    throw error;
  }
}
