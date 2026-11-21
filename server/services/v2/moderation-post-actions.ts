import { getRouterParam, setResponseHeader } from 'h3';
import type { H3Event } from 'h3';
import type { Connection } from 'oracledb';
import contract from '../../../specifications/requirements/moderation-post-actions.json';
import {
  v2BadRequest, v2Body, v2Conflict, v2Execute, v2Forbidden, v2NotFound, v2Ok, v2One, v2Rows, v2ServerError
} from '~/server/utils/v2';
import { ensureModerationSchema, readModerationContent, requireModerationAccess } from './moderation';

type Action = keyof typeof contract.actions;

function postId(value: unknown): number {
  const id = typeof value === 'number' ? value :
    typeof value === 'string' && /^[1-9][0-9]*$/.test(value) ? Number(value) : 0;
  if (!Number.isSafeInteger(id) || id <= 0) v2BadRequest('post_id 参数错误');
  return id;
}

function text(value: unknown, max: number, field: 'note' | 'reason'): string {
  if (value === undefined || value === null) return '';
  if (typeof value !== 'string') v2BadRequest(`${field} 参数错误`);
  const content = value.trim();
  if (content.includes('\0') || Buffer.byteLength(content) > max) v2BadRequest(`${field} 参数错误`);
  return content;
}

async function apply<T>(
  event: H3Event,
  connection: Connection,
  bulk: boolean,
  readResult: (ids: number[], viewerId: number) => T | Promise<T>
): Promise<T> {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const {userId:viewer_id} = await requireModerationAccess(event, connection);
  const body = await v2Body(event);
  const action = body.action === undefined ? 'flag' : typeof body.action === 'string' ? body.action.trim() : '';
  if (!Object.hasOwn(contract.actions, action) || (bulk && (action === 'claim' || action === 'release'))) {
    v2BadRequest('action 参数错误');
  }
  const note = text(body.note,contract.maxNoteBytes,'note');
  const reason = text(body.reason,contract.maxReasonBytes,'reason');
  let ids: number[];
  if (bulk) {
    if (!Array.isArray(body.post_ids) || !body.post_ids.length || body.post_ids.length > contract.maxPosts) {
      v2BadRequest('post_ids 参数错误');
    }
    ids = [...new Set((body.post_ids as unknown[]).map(postId))].sort((a,b) => a-b);
  } else {
    ids = [postId(getRouterParam(event,'post_id',{decode:true}))];
  }
  const spec = contract.actions[action as Action];
  const queries = contract.sql;
  await ensureModerationSchema(connection);
  try {
    const settings = await v2Rows(connection,queries.settings);
    const enabled = (key: string) => !['0','false'].includes(
      String(settings.find(row => row.SETTING_KEY === key)?.SETTING_VALUE ?? '').trim().toLowerCase()
    );
    if ((action === 'claim' || action === 'release') && !enabled('allow_moderator_claim')) v2Forbidden('审核领取已关闭');
    if ((action === 'reject' || action === 'remove') && enabled('require_note_on_reject') && !note) v2BadRequest('请填写审核备注');
    for (const post_id of ids) {
      if (!await v2One(connection,queries.post,{post_id})) v2NotFound('帖子不存在');
    }
    for (const post_id of ids) {
      let current = await v2One(connection,queries.case,{post_id});
      if (!current) {
        if (await v2Execute(connection,queries.create,{post_id},false) !== 1) v2ServerError();
        current = await v2One(connection,queries.case,{post_id});
      }
      const case_id = Number(current?.CASE_ID);
      if (!Number.isSafeInteger(case_id) || case_id <= 0) v2ServerError();
      const assigned = Number(current?.ASSIGNED_TO);
      if ((action === 'claim' || action === 'release') && assigned && assigned !== viewer_id) v2Conflict('案件由其他审核员领取');
      if (spec.deleted !== null && await v2Execute(connection,queries.updatePost,{post_id,deleted:spec.deleted},false) !== 1) v2ServerError();
      if (await v2Execute(connection,queries.updateCase,{case_id,status:spec.status,action,viewer_id},false) !== 1) v2ServerError();
      await v2Execute(connection,queries.updateReports,{post_id,status:spec.report,viewer_id},false);
      if (await v2Execute(connection,queries.audit,{case_id,post_id,action,viewer_id,reason:reason || null,note:note || null},false) !== 1) v2ServerError();
    }
    const result = await readResult(ids,viewer_id);
    await connection.commit();
    return result;
  } catch (error) {
    try { await connection.rollback(); } catch { v2ServerError(); }
    throw error;
  }
}

export async function v2ModeratePost(event: H3Event, connection: Connection) {
  const result = await apply(event,connection,false,async ([post_id],viewer_id) => {
    const {items:[item]} = await readModerationContent(connection,{viewer_id,post_id,start_row:1,end_row:1});
    if (!item) v2ServerError();
    return item;
  });
  return v2Ok(result,'moderation action applied');
}

export async function v2BulkModeratePosts(event: H3Event, connection: Connection) {
  const result = await apply(event,connection,true,ids => ({processed_count:ids.length}));
  return v2Ok(result,'bulk moderation action applied');
}
