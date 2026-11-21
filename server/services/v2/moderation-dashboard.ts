import { setResponseHeader } from 'h3';
import type { H3Event } from 'h3';
import type { Connection } from 'oracledb';
import type { V2ModerationSetting, V2ModerationStats } from '../../../app/types/v2';
import contract from '../../../specifications/requirements/moderation-dashboard.json';
import {
  v2BadRequest, v2Body, v2Execute, v2Number, v2Ok, v2One, v2Rows, v2ServerError, v2String
} from '~/server/utils/v2';
import { ensureModerationSchema, requireModerationAccess } from './moderation';

async function access(event: H3Event, connection: Connection): Promise<number> {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const {userId} = await requireModerationAccess(event, connection);
  await ensureModerationSchema(connection);
  return userId;
}

async function list(connection: Connection): Promise<V2ModerationSetting[]> {
  return (await v2Rows(connection, contract.sql.list)).map(row => ({
    key: v2String(row.SETTING_KEY),
    value: v2String(row.SETTING_VALUE),
    value_type: row.VALUE_TYPE === 'boolean' || row.VALUE_TYPE === 'number' ? row.VALUE_TYPE : 'string',
    label: v2String(row.LABEL),
    description: v2String(row.DESCRIPTION),
    updated_at: v2String(row.UPDATED_AT)
  }));
}

function changes(input: unknown) {
  if (!Array.isArray(input) || input.length > Object.keys(contract.settings).length) {
    v2BadRequest('settings 参数错误');
  }
  const seen = new Set<string>();
  return input.map(item => {
    if (!item || typeof item !== 'object' || typeof item.key !== 'string' ||
      !Object.hasOwn(contract.settings, item.key) || seen.has(item.key)) v2BadRequest('settings 参数错误');
    const setting_key: string = item.key;
    seen.add(setting_key);
    const value_type = contract.settings[setting_key as keyof typeof contract.settings];
    const value: unknown = item.value;
    const raw = typeof value === 'string' ? value.trim() : value;
    let setting_value: string;
    if (value_type === 'boolean') {
      if (raw === true || raw === 'true' || raw === '1') setting_value = 'true';
      else if (raw === false || raw === 'false' || raw === '0') setting_value = 'false';
      else v2BadRequest('settings 参数错误');
    } else {
      const n = typeof raw === 'number' ? raw : typeof raw === 'string' && /^\d+$/.test(raw) ? Number(raw) : -1;
      if (!Number.isSafeInteger(n) || n < 0 || n > contract.maxNumber) v2BadRequest('settings 参数错误');
      setting_value = String(n);
    }
    return { setting_key, setting_value, value_type };
  }).sort((a, b) => a.setting_key < b.setting_key ? -1 : 1);
}

export async function v2GetModerationStats(event: H3Event, connection: Connection) {
  await access(event, connection);
  const row = await v2One(connection, contract.sql.stats);
  if (!row) v2ServerError();
  const stats: V2ModerationStats = {
    pending: v2Number(row.PENDING), approved: v2Number(row.APPROVED),
    rejected: v2Number(row.REJECTED), flagged: v2Number(row.FLAGGED),
    today_processed: v2Number(row.TODAY_PROCESSED), avg_process_minutes: v2Number(row.AVG_PROCESS_MINUTES),
    open_reports: v2Number(row.OPEN_REPORTS), appeal_success_rate: v2Number(row.APPEAL_SUCCESS_RATE)
  };
  return v2Ok(stats);
}

export async function v2GetModerationSettings(event: H3Event, connection: Connection) {
  await access(event, connection);
  return v2Ok(await list(connection));
}

export async function v2PatchModerationSettings(event: H3Event, connection: Connection) {
  const updated_by = await access(event, connection);
  const body = await v2Body(event);
  const batch = changes(body.settings);
  if (!batch.length) return v2Ok(await list(connection));
  try {
    for (const entry of batch) {
      if (await v2Execute(connection, contract.sql.update, {...entry, updated_by}, false) !== 1) {
        v2ServerError();
      }
    }
    const settings = await list(connection);
    await connection.commit();
    return v2Ok(settings);
  } catch (error) {
    try { await connection.rollback(); } catch { v2ServerError(); }
    throw error;
  }
}
