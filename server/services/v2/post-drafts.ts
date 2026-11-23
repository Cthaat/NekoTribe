import { getQuery, setResponseHeader, type H3Event } from 'h3';
import oracledb, { type Connection } from 'oracledb';
import { z } from 'zod';
import policy from '../../../specifications/requirements/post-drafts.json';
import type { V2PostDraft, V2PostDraftInput, V2PostDraftList } from '../../../app/types/v2';
import { requireFeatureSchema } from '~/server/database/readiness';
import { logWarn } from '~/server/utils/logging';
import {
  v2Auth, v2BadRequest, v2Body, v2Conflict, v2Execute, v2NextId, v2NotFound, v2Number, v2Ok,
  v2RouterParam, v2Rows, v2ServerError, v2String, v2StringOrNull, type V2DbRecord,
} from '~/server/utils/v2';
import { readGroupPostWrite, requireGroupPostPublishAccess, v2EnsureGroupFeatureSchema,
  v2InsertGroupPost, v2NotifyGroupPostCreated } from './groups';
import { requirePublishAccess } from './moderation-publish-policy';
import { readPollCreation } from './post-polls';
import { readPostMarkdownInput } from './post-markdown';
import { v2InsertPost, v2NotifyPostCreated } from './posts';

type DraftAction = 'list' | 'create' | 'edit' | 'remove' | 'schedule' | 'unschedule' | 'publish';
type OwnerKey = { draft_id: number; owner_id: number };
type StoredDraft = V2PostDraft & { ownerId: number };
type DraftWrite = { draft: V2PostDraft; created?: number };

const { sql } = policy;
const dateTime = z.string().datetime({offset: true});
const plainFields = ['visibility', 'media_ids', 'tag_names', 'mention_user_ids', 'location'];
const groupedFields = ['media_urls', 'is_announcement'];
const visibilities = ['public', 'followers', 'mentioned', 'private'] as const;

export const postDraftSweepIntervalMs = policy.sweep_interval_seconds * 1000;

function isId(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value > 0;
}

function optionalIds(value: unknown, max: number, name: string): number[] | undefined {
  if (value === undefined) return;
  if (!Array.isArray(value) || value.length > max || !value.every(isId)) v2BadRequest(`${name} 参数错误`);
  return value;
}

function optionalStrings(value: unknown, max: number, bytes: number, name: string): string[] | undefined {
  if (value === undefined) return;
  if (!Array.isArray(value) || value.length > max || value.some(item => typeof item !== 'string' || Buffer.byteLength(item) > bytes)) {
    v2BadRequest(`${name} 参数错误`);
  }
  return value as string[];
}

export function readPostDraftInput(body: Record<string, unknown>): V2PostDraftInput {
  const groupId = body.group_id;
  const content = body.content;
  if ((groupId !== null && !isId(groupId)) || typeof content !== 'string' || Buffer.byteLength(content) > 4000) {
    v2BadRequest('group_id 或 content 参数错误');
  }
  const fields = ['group_id', 'content', 'poll', 'markdown', ...(groupId === null ? plainFields : groupedFields)];
  if (Object.keys(body).some(key => !fields.includes(key))) v2BadRequest('草稿字段与发布范围不匹配');
  const poll = readPollCreation(body.poll);
  const markdown = readPostMarkdownInput(body.markdown);
  if (groupId === null) {
    const { visibility, location } = body;
    if (visibility !== undefined && !visibilities.some(item => item === visibility)) v2BadRequest('visibility 参数错误');
    if (location !== undefined && (typeof location !== 'string' || Buffer.byteLength(location) > 100)) v2BadRequest('location 参数错误');
    return { group_id: null, content, poll, markdown, visibility: visibility as typeof visibilities[number] | undefined, location,
      media_ids: optionalIds(body.media_ids, 4, 'media_ids'),
      tag_names: optionalStrings(body.tag_names, 20, 100, 'tag_names'),
      mention_user_ids: optionalIds(body.mention_user_ids, 50, 'mention_user_ids') };
  }
  const { is_announcement } = body;
  if (is_announcement !== undefined && typeof is_announcement !== 'boolean') v2BadRequest('is_announcement 参数错误');
  const mediaUrls = optionalStrings(body.media_urls, 4, 2000, 'media_urls');
  if (mediaUrls?.some(url => url.includes(',')) || Buffer.byteLength((mediaUrls ?? []).join(',')) > 2000) v2BadRequest('media_urls 参数错误');
  return { group_id: groupId, content, media_urls: mediaUrls, is_announcement, poll, markdown };
}

function queryId(value: unknown, name: string, min: number, max = Number.MAX_SAFE_INTEGER): number {
  if (typeof value !== 'string' || !/^(0|[1-9]\d*)$/.test(value)) v2BadRequest(`${name} 参数错误`);
  const id = Number(value);
  if (!Number.isSafeInteger(id) || id < min || id > max) v2BadRequest(`${name} 参数错误`);
  return id;
}

function scheduleTime(body: Record<string, unknown>): string {
  const value = dateTime.safeParse(body.scheduled_at);
  if (Object.keys(body).length !== 1 || !value.success) v2BadRequest('scheduled_at 参数错误');
  const date = new Date(value.data);
  if (!Number.isFinite(date.getTime()) || date.getUTCFullYear() < 1 || date.getUTCFullYear() > 9999) v2BadRequest('scheduled_at 参数错误');
  return date.toISOString();
}

async function rows(connection: Connection, statement: string, binds: Record<string, string | number | null>) {
  const result = await connection.execute<V2DbRecord>(statement, binds, {
    outFormat: oracledb.OUT_FORMAT_OBJECT,
    fetchTypeHandler: metadata => metadata.name === 'PAYLOAD_JSON' ? {type: oracledb.STRING} : undefined,
  });
  return result.rows ?? [];
}

function mapDraft(row: V2DbRecord): StoredDraft {
  const groupId = row.GROUP_ID === null ? null : v2Number(row.GROUP_ID);
  let payload: V2PostDraftInput;
  try {
    payload = readPostDraftInput(JSON.parse(v2String(row.PAYLOAD_JSON)));
  } catch {
    v2ServerError();
  }
  if (groupId !== payload.group_id) v2ServerError();
  return {
    ownerId: v2Number(row.OWNER_ID), draft_id: v2Number(row.DRAFT_ID), payload,
    status: v2String(row.STATUS) as V2PostDraft['status'], scheduled_at: v2StringOrNull(row.SCHEDULED_AT),
    published_post_id: row.PUBLISHED_POST_ID == null ? null : v2Number(row.PUBLISHED_POST_ID),
    last_error: v2StringOrNull(row.LAST_ERROR) as V2PostDraft['last_error'], updated_at: v2String(row.UPDATED_AT),
  };
}

function publicDraft(draft: StoredDraft): V2PostDraft {
  const { ownerId: _ownerId, ...result } = draft;
  return result;
}

async function readOwned(connection: Connection, key: OwnerKey, lock = false) {
  const [row] = await rows(connection, lock ? sql.lock_owner : sql.read, key);
  if (!row) v2NotFound('草稿不存在');
  return mapDraft(row);
}

async function listDrafts(event: H3Event, connection: Connection, ownerId: number): Promise<V2PostDraftList> {
  const query = getQuery(event);
  const beforeId = query.before_id === undefined ? null : queryId(query.before_id, 'before_id', 1);
  const groupScope = query.group_id === undefined ? null : queryId(query.group_id, 'group_id', 0);
  const limit = query.limit === undefined ? policy.default_list_limit : queryId(query.limit, 'limit', 1, policy.max_list_limit);
  const found = await rows(connection, sql.list, {owner_id: ownerId, before_id: beforeId, group_scope: groupScope, fetch_limit: limit + 1});
  const items = found.slice(0, limit).map(row => publicDraft(mapDraft(row)));
  return {items, next_before_id: found.length > limit ? items.at(-1)!.draft_id : null};
}

async function transaction<T>(connection: Connection, work: () => Promise<T>) {
  try {
    const result = await work();
    await connection.commit();
    return result;
  } catch (error) {
    await connection.rollback();
    throw error;
  }
}

function requireEditable(draft: StoredDraft) {
  if (draft.status === 'published') v2Conflict('草稿已发布');
}

async function saveDraft(connection: Connection, ownerId: number, id: number | null, body: Record<string, unknown>) {
  const payload = readPostDraftInput(body);
  const json = JSON.stringify(payload);
  if (Buffer.byteLength(json) > policy.max_payload_bytes) v2BadRequest('草稿内容过长');
  const key = {draft_id: id ?? await v2NextId(connection, 'seq_post_draft_id'), owner_id: ownerId};
  return transaction(connection, async () => {
    if (id !== null) requireEditable(await readOwned(connection, key, true));
    const written = await v2Execute(connection, id === null ? sql.insert : sql.edit,
      {...key, group_id: payload.group_id, payload_json: json}, false);
    if (written !== 1) v2ServerError();
    return publicDraft(await readOwned(connection, key));
  });
}

async function changeSchedule(connection: Connection, key: OwnerKey, at: string | null) {
  return transaction(connection, async () => {
    const draft = await readOwned(connection, key, true);
    requireEditable(draft);
    if (at !== null) {
      const { payload } = draft;
      if (payload.poll && Date.parse(payload.poll.closes_at) <= Date.parse(at)) v2BadRequest('投票截止时间必须晚于定时发布时间');
      if (payload.group_id === null) {
        if (!payload.content.trim() && !payload.media_ids?.length) v2BadRequest('content 不能为空');
        await requirePublishAccess(connection, key.owner_id);
      } else {
        const groupPost = readGroupPostWrite({...payload});
        await v2EnsureGroupFeatureSchema(connection);
        await requireGroupPostPublishAccess(connection, key.owner_id, payload.group_id, groupPost.announcement);
      }
      if (payload.poll) await requireFeatureSchema(connection, 'post-polls');
      if (payload.markdown !== undefined) await requireFeatureSchema(connection, 'post-markdown');
      if (await v2Execute(connection, sql.schedule, {...key, scheduled_at: at}, false) !== 1) v2BadRequest('定时发布时间必须晚于当前时间');
    } else if (await v2Execute(connection, sql.unschedule, key, false) !== 1) {
      v2ServerError();
    }
    return publicDraft(await readOwned(connection, key));
  });
}

async function publishDraft(connection: Connection, draft: StoredDraft): Promise<DraftWrite> {
  if (draft.status === 'published') return {draft: publicDraft(draft)};
  const { ownerId, payload } = draft;
  let postId: number;
  if (payload.group_id === null) {
    const post = await v2InsertPost(connection, ownerId, payload);
    postId = post.postId;
  } else {
    await v2EnsureGroupFeatureSchema(connection);
    if (payload.poll) await requireFeatureSchema(connection, 'post-polls');
    postId = await v2InsertGroupPost(connection, ownerId, payload.group_id, readGroupPostWrite({...payload}));
  }
  const key = {draft_id: draft.draft_id, owner_id: ownerId};
  if (await v2Execute(connection, sql.published, {...key, post_id: postId}, false) !== 1) v2ServerError();
  return {draft: publicDraft(await readOwned(connection, key)), created: postId};
}

async function notifyPublication(connection: Connection, ownerId: number, result: DraftWrite) {
  if (result.created === undefined) return;
  const { payload } = result.draft;
  try {
    if (payload.group_id === null) await v2NotifyPostCreated(connection, ownerId, result.created, 'post', payload);
    else await v2NotifyGroupPostCreated(connection, payload.group_id, result.created, ownerId, payload.content.trim());
  } catch {
    logWarn('post-draft:publication-notification-unavailable', { draftId: result.draft.draft_id });
  }
}

function failureReason(error: unknown): V2PostDraft['last_error'] {
  if (typeof error !== 'object' || error === null || !('statusCode' in error)) return null;
  if (error.statusCode === 400) return 'content_unavailable';
  if (error.statusCode === 403 || error.statusCode === 404 || error.statusCode === 422) return 'permission_denied';
  return null;
}

async function publishDueDraft(connection: Connection, id: number) {
  let ownerId = 0;
  const result = await transaction(connection, async () => {
    const [row] = await rows(connection, sql.lock_due, {draft_id: id});
    if (!row) return;
    const draft = mapDraft(row);
    ownerId = draft.ownerId;
    await connection.execute('SAVEPOINT post_draft_publish');
    try {
      return await publishDraft(connection, draft);
    } catch (error) {
      const reason = failureReason(error);
      if (!reason) throw error;
      await connection.execute('ROLLBACK TO SAVEPOINT post_draft_publish');
      if (await v2Execute(connection, sql.failed, {draft_id: id, owner_id: ownerId, reason}, false) !== 1) v2ServerError();
    }
  });
  if (result) await notifyPublication(connection, ownerId, result);
}

export async function sweepPostDrafts(connection: Connection) {
  await requireFeatureSchema(connection, 'post-drafts');
  const candidates = await v2Rows(connection, sql.candidates);
  for (const row of candidates) {
    const id = v2Number(row.DRAFT_ID);
    try { await publishDueDraft(connection, id); }
    catch { logWarn('post-draft:sweep-item-unavailable', { draftId: id }); }
  }
}

export async function v2PostDraftRequest(event: H3Event, connection: Connection, action: DraftAction):
Promise<V2Response<V2PostDraft | V2PostDraftList | null>> {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const { userId } = v2Auth(event);
  await requireFeatureSchema(connection, 'post-drafts');
  if (action === 'list') return v2Ok(await listDrafts(event, connection, userId));
  if (action === 'create') return v2Ok(await saveDraft(connection, userId, null, await v2Body(event)), 'draft saved');
  const draftId = queryId(v2RouterParam(event, 'id'), 'id', 1);
  const key = {draft_id: draftId, owner_id: userId};
  if (action === 'edit') return v2Ok(await saveDraft(connection, userId, draftId, await v2Body(event)), 'draft saved');
  if (action === 'remove') {
    await transaction(connection, async () => {
      if (await v2Execute(connection, sql.remove, key, false) !== 1) v2NotFound('草稿不存在');
    });
    return v2Ok(null, 'draft deleted');
  }
  if (action === 'schedule') return v2Ok(await changeSchedule(connection, key, scheduleTime(await v2Body(event))), 'draft scheduled');
  if (action === 'unschedule') return v2Ok(await changeSchedule(connection, key, null), 'draft unscheduled');
  const result = await transaction(connection, async () => publishDraft(connection, await readOwned(connection, key, true)));
  await notifyPublication(connection, userId, result);
  return v2Ok(result.draft, 'draft published');
}
