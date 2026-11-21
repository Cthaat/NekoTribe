import { getRouterParam, setResponseHeader } from 'h3';
import type { H3Event } from 'h3';
import type { Connection } from 'oracledb';
import contract from '../../../specifications/requirements/moderation-user-actions.json';
import {
  v2BadRequest, v2Body, v2Conflict, v2Execute, v2Forbidden, v2NotFound, v2Ok, v2One, v2ServerError
} from '~/server/utils/v2';
import { ensureModerationSchema, requireModerationAccess } from './moderation';
import { readModerationUsers } from './moderation-user-queue';

function parseHours(value: unknown): number | null {
  const raw = typeof value === 'string' ? value.trim() : value;
  const hours = typeof raw === 'number' ? raw :
    typeof raw === 'string' && /^\d+$/.test(raw) ? Number(raw) : NaN;
  return Number.isSafeInteger(hours) && hours >= 0 && hours <= contract.maxDurationHours ? hours : null;
}

export async function v2ModerateUser(event: H3Event, connection: Connection) {
  setResponseHeader(event,'Cache-Control','private, no-store');
  const {userId:viewer_id} = await requireModerationAccess(event,connection);
  const raw = getRouterParam(event,'user_id',{decode:true}) ?? '';
  const user_id = Number(raw);
  if (!/^[1-9][0-9]*$/.test(raw) || !Number.isSafeInteger(user_id)) v2BadRequest('user_id 参数错误');
  if (user_id === viewer_id) v2Forbidden('不能处罚自己');
  const body = await v2Body(event);
  const action = typeof body.action === 'string' ? body.action.trim() : '';
  if (!contract.actions.includes(action)) v2BadRequest('action 参数错误');
  const text = (field: 'reason' | 'note', max: number) => {
    const raw = body[field];
    if (raw === undefined || raw === null) return '';
    if (typeof raw !== 'string') v2BadRequest(`${field} 参数错误`);
    const value = raw.trim();
    if (value.includes('\0') || Buffer.byteLength(value) > max) v2BadRequest(`${field} 参数错误`);
    return value;
  };
  const reason = text('reason',contract.maxReasonBytes) || null;
  const note = text('note',contract.maxNoteBytes) || null;
  const adding = action === 'ban' || action === 'mute';
  let hours: number | null = null;
  if (adding && Object.hasOwn(body,'duration_hours')) {
    hours = parseHours(body.duration_hours);
    if (hours === null || (action === 'mute' && hours === 0)) v2BadRequest('duration_hours 参数错误');
  }

  const sql = contract.sql;
  const key = {user_id};
  await ensureModerationSchema(connection);
  try {
    const target = await v2One(connection,sql.lock,key);
    if (!target) v2NotFound('用户不存在');
    const banState = target.STATUS === 'suspended' && Number(target.IS_ACTIVE) === 0;
    const activeState = target.STATUS === 'active' && Number(target.IS_ACTIVE) === 1;
    if (action === 'ban' || action === 'unban') {
      if (!activeState && (!banState || !await v2One(connection,sql.banHistory,key))) {
        v2Conflict('账号状态不允许此处置');
      }
    }
    if (hours === null && adding) {
      const setting = action === 'mute' ? await v2One(connection,sql.defaultMute) : null;
      const fallback = parseHours(setting?.SETTING_VALUE) ?? contract.defaultDurationHours;
      hours = action === 'mute' ? Math.max(fallback,1) : fallback;
    }
    const exact = async (query: string, params: Record<string,string|number|null>) => {
      if (await v2Execute(connection,query,params,false) !== 1) v2ServerError();
    };
    let record = await v2One(connection,sql.case,key);
    if (!record) {
      await exact(sql.create,key);
      record = await v2One(connection,sql.case,key);
    }
    const case_id = Number(record?.CASE_ID);
    if (!Number.isSafeInteger(case_id) || case_id <= 0) v2ServerError();
    if (action === 'ban' || (action === 'unban' && banState)) {
      await exact(sql.updateUser,{user_id,status:action === 'ban' ? 'suspended' : 'active',active:action === 'ban' ? 0 : 1});
    }
    if (action === 'ban') await v2Execute(connection,sql.revokeSessions,key,false);
    if (action !== 'note') {
      const kind = action === 'ban' || action === 'unban' ? 'ban' : 'mute';
      const params = {user_id,viewer_id,kind};
      await v2Execute(connection,sql.revokeRestriction,params,false);
      if (adding) await exact(sql.addRestriction,{...params,reason,hours});
    }
    await exact(sql.audit,{user_id,viewer_id,case_id,action,reason,note,hours});
    const {items:[user]} = await readModerationUsers(connection,{userId:user_id,start:1,end:1});
    if (!user) v2ServerError();
    await connection.commit();
    return v2Ok(user,'user moderation action applied');
  } catch (error) {
    try { await connection.rollback(); } catch { v2ServerError(); }
    throw error;
  }
}
