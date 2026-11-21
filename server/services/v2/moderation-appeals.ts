import { getRouterParam, setResponseHeader } from 'h3';
import type { H3Event } from 'h3';
import type { Connection } from 'oracledb';
import type { V2ModerationAppeal } from '../../../app/types/v2';
import contract from '../../../specifications/requirements/moderation-appeals.json';
import { v2MapPublicUser } from '~/server/models/v2';
import {
  v2BadRequest, v2Body, v2Conflict, v2Execute, v2NotFound, v2Ok, v2One,
  v2Page, v2PageMeta, v2QueryString, v2Rows, v2ServerError, v2String
} from '~/server/utils/v2';
import { requireModerationAccess } from './moderation';

function mapAppeal(row: Record<string, unknown>): V2ModerationAppeal {
  return {
    appeal_id: Number(row.APPEAL_ID),
    statement_id: Number(row.STATEMENT_ID),
    user: v2MapPublicUser(row),
    appeal_message: v2String(row.APPEAL_MESSAGE),
    appeal_status: row.APPEAL_STATUS === 'approved' || row.APPEAL_STATUS === 'rejected' ? row.APPEAL_STATUS : 'pending',
    admin_response: v2String(row.ADMIN_RESPONSE),
    created_at: v2String(row.CREATED_AT),
    updated_at: v2String(row.UPDATED_AT)
  };
}

export async function v2ListModerationAppeals(event: H3Event, connection: Connection) {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const {userId} = await requireModerationAccess(event, connection);
  const page = v2Page(event);
  const filter = v2QueryString(event, 'status', 'all');
  const status = filter === 'all' ? null : contract.statuses.includes(filter) ? filter : 'pending';
  const rows = await v2Rows(connection, contract.sql.list, {
    viewer_id: userId, status, start_row: page.start, end_row: page.end
  });
  return v2Ok(rows.filter(row => Number(row.APPEAL_ID) > 0).map(mapAppeal),
    'moderation appeals listed', v2PageMeta(page.page, page.page_size, Number(rows[0]?.TOTAL ?? 0)));
}

export async function v2PatchModerationAppeal(event: H3Event, connection: Connection) {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const {userId} = await requireModerationAccess(event, connection);
  const raw = getRouterParam(event, 'appeal_id', {decode: true}) ?? '';
  const appeal_id = Number(raw);
  if (!/^[1-9][0-9]*$/.test(raw) || !Number.isSafeInteger(appeal_id)) v2BadRequest('appeal_id 参数错误');
  const body = await v2Body(event);
  const status = typeof body.appeal_status === 'string' ? body.appeal_status.trim() : '';
  if (!contract.decisions.includes(status)) v2BadRequest('appeal_status 参数错误');
  if (body.admin_response !== undefined && typeof body.admin_response !== 'string') v2BadRequest('admin_response 参数错误');
  const reply = v2String(body.admin_response).trim();
  if (Buffer.byteLength(reply) > contract.maxResponseBytes || reply.includes('\0')) v2BadRequest('admin_response 参数错误');

  try {
    const lock = await v2One(connection, contract.sql.lock, {appeal_id});
    if (!lock) v2NotFound('申诉不存在');
    if (lock.APPEAL_STATUS === 'pending') {
      const response = reply || null;
      if (await v2Execute(connection, contract.sql.update, {appeal_id, status, response}, false) !== 1) v2ServerError();
      if (await v2Execute(connection, contract.sql.audit, {
        target_id: Number(lock.USER_ID), viewer_id: userId, action: 'appeal_' + status, reason: 'appeal:' + appeal_id, response
      }, false) !== 1) v2ServerError();
    } else if (lock.APPEAL_STATUS !== status || v2String(lock.ADMIN_RESPONSE) !== reply) {
      v2Conflict('申诉已处理');
    }
    const row = await v2One(connection, contract.sql.read, {viewer_id: userId, appeal_id});
    if (!row || Number(row.APPEAL_ID) !== appeal_id || Number(row.USER_ID) <= 0) v2ServerError();
    const result = mapAppeal(row);
    await connection.commit();
    return v2Ok(result, 'appeal updated');
  } catch (error) {
    try { await connection.rollback(); } catch { v2ServerError(); }
    throw error;
  }
}
