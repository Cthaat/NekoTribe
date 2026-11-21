import { getRouterParam, setResponseHeader } from 'h3';
import type { H3Event } from 'h3';
import type { Connection } from 'oracledb';
import contract from '../../../specifications/requirements/moderation-reports.json';
import {
  v2Auth, v2BadRequest, v2Body, v2Conflict, v2Execute, v2Forbidden, v2NotFound, v2Ok, v2One,
  v2Page, v2PageMeta, v2QueryString, v2Rows, v2ServerError
} from '~/server/utils/v2';
import { ensureModerationSchema, mapReport, requireModerationAccess } from './moderation';

const evidenceLink = new RegExp(contract.create.evidencePattern);

function requiredChoice(value: unknown, field: string, choices: string[]): string {
  const choice = typeof value === 'string' ? value.trim() : '';
  if (!choices.includes(choice)) v2BadRequest(`${field} 参数错误`);
  return choice;
}

function reportText(value: unknown, field: string): string {
  if (value === null || value === undefined) return '';
  if (typeof value !== 'string') v2BadRequest(`${field} 参数错误`);
  const text = value.trim();
  if (Buffer.byteLength(text) > contract.create.maxTextBytes || text.includes('\0')) {
    v2BadRequest(`${field} 参数错误`);
  }
  return text;
}

export async function v2CreateReport(event: H3Event, connection: Connection) {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const { userId: viewer_id } = v2Auth(event);
  const body = await v2Body(event);
  const target_type = requiredChoice(body.target_type, 'target_type', contract.targetTypes) as keyof typeof contract.create.targets;
  const value = body.target_id;
  const target_id = typeof value === 'number' ? value :
    typeof value === 'string' && /^[1-9][0-9]*$/.test(value) ? Number(value) : 0;
  if (!Number.isSafeInteger(target_id) || target_id <= 0) v2BadRequest('target_id 参数错误');
  const reason = requiredChoice(body.reason, 'reason', contract.reasons);
  const priority = body.priority === undefined ? 'normal' : requiredChoice(body.priority, 'priority', contract.create.priorities);
  const description = reportText(body.description, 'description');
  const evidence_url = reportText(body.evidence_url, 'evidence_url');
  if (evidence_url && !evidenceLink.test(evidence_url)) v2BadRequest('evidence_url 参数错误');
  if (target_type === 'user' && target_id === viewer_id) v2Forbidden('不能举报自己');
  await ensureModerationSchema(connection);

  try {
    if (!await v2One(connection, contract.create.targets[target_type], { target_id, viewer_id })) {
      v2NotFound('举报目标不存在');
    }
    const scope = { target_type, target_id };
    const actor = { ...scope, viewer_id };
    const open = await v2One(connection, contract.sql.findOpen, actor);
    let report_id: number;
    if (open) {
      if (open.REASON !== reason || open.PRIORITY !== priority ||
          (open.DESCRIPTION ?? '') !== description || (open.EVIDENCE_URL ?? '') !== evidence_url) {
        v2Conflict('已有待处理举报');
      }
      report_id = Number(open.REPORT_ID);
    } else {
      report_id = Number((await v2One(connection, contract.sql.next))?.REPORT_ID);
      if (!Number.isSafeInteger(report_id) || report_id <= 0) v2ServerError();
      const inserted = await v2Execute(connection, contract.sql.insert, {
        ...actor, report_id, reason, priority, description: description || null, evidence_url: evidence_url || null
      }, false);
      if (inserted !== 1 || await v2Execute(connection, contract.sql.mergeCase, scope, false) !== 1) {
        v2ServerError();
      }
    }
    const row = await v2One(connection, contract.sql.read, { report_id });
    if (!row) v2ServerError();
    const report = await mapReport(connection, viewer_id, row);
    await connection.commit();
    return v2Ok(report, 'report created');
  } catch (error) {
    try { await connection.rollback(); } catch { v2ServerError(); }
    throw error;
  }
}

function filter(event: H3Event, key: string, values: string[], fallback: string): string | null {
  const raw = v2QueryString(event, key, 'all');
  return raw === 'all' ? null : values.includes(raw) ? raw : fallback;
}

export async function v2ListModerationReports(event: H3Event, connection: Connection) {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const { userId } = await requireModerationAccess(event, connection);
  await ensureModerationSchema(connection);
  const page = v2Page(event);
  const rows = await v2Rows(connection, contract.sql.list, {
    status: filter(event, 'status', contract.statuses, 'pending'),
    reason: filter(event, 'reason', contract.reasons, 'other'),
    target_type: filter(event, 'target_type', contract.targetTypes, 'post'),
    start_row: page.start,
    end_row: page.end
  });
  const reports = await Promise.all(rows.filter(row => Number(row.REPORT_ID) > 0)
    .map(row => mapReport(connection, userId, row)));
  return v2Ok(reports, 'moderation reports listed',
    v2PageMeta(page.page, page.page_size, Number(rows[0]?.TOTAL ?? 0)));
}

export async function v2PatchModerationReport(event: H3Event, connection: Connection) {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const { userId } = await requireModerationAccess(event, connection);
  await ensureModerationSchema(connection);
  const raw = getRouterParam(event, 'report_id', { decode: true }) ?? '';
  const report_id = Number(raw);
  if (!/^[1-9][0-9]*$/.test(raw) || !Number.isSafeInteger(report_id)) v2BadRequest('report_id 参数错误');
  const body = await v2Body(event);
  const status = typeof body.status === 'string' ? body.status.trim() : '';
  if (!contract.statuses.includes(status)) v2BadRequest('status 参数错误');

  try {
    const current = await v2One(connection, contract.sql.lock, { report_id });
    if (!current) v2NotFound('举报不存在');
    const terminal = status === 'resolved' || status === 'dismissed';
    if (current.STATUS !== status || Number(current.HANDLED_BY) !== userId || Number(current.IS_RESOLVED) !== Number(terminal)) {
      if (await v2Execute(connection, contract.sql.update, { report_id, status, handled_by: userId }, false) !== 1) {
        v2ServerError();
      }
    }
    const row = await v2One(connection, contract.sql.read, { report_id });
    if (!row) v2ServerError();
    const report = await mapReport(connection, userId, row);
    await connection.commit();
    return v2Ok(report, 'report updated');
  } catch (error) {
    try { await connection.rollback(); } catch { v2ServerError(); }
    throw error;
  }
}
