import { getRouterParam, setResponseHeader } from 'h3';
import type { H3Event } from 'h3';
import type { Connection } from 'oracledb';
import contract from '../../../specifications/requirements/account-statements.json';
import {
  v2Auth, v2BadRequest, v2Body, v2Conflict, v2Execute, v2NotFound, v2Ok,
  v2One, v2Page, v2PageMeta, v2QueryString, v2Rows, v2ServerError, v2String
} from '~/server/utils/v2';

function owner(event: H3Event) {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  return v2Auth(event).userId;
}

function target(event: H3Event) {
  const user_id = owner(event);
  const raw = getRouterParam(event, 'id', { decode: true }) ?? '';
  const statement_id = Number(raw);
  if (!/^[1-9][0-9]*$/.test(raw) || !Number.isSafeInteger(statement_id)) v2BadRequest('id 参数错误');
  return { user_id, statement_id };
}

function filter(event: H3Event, key: 'status' | 'type') {
  const value = v2QueryString(event, key);
  return value === 'all' || value === '' ? null : value;
}

export async function v2ListAccountStatements(event: H3Event, connection: Connection): Promise<V2Response<V2AccountStatement[]>> {
  const user_id = owner(event);
  const page = v2Page(event);
  const rows = await v2Rows(connection, contract.sql.list, {
    user_id, status: filter(event, 'status'), statement_type: filter(event, 'type'),
    start_row: page.start, end_row: page.end
  });
  const data = rows.filter(row => Number(row.STATEMENT_ID) > 0).map(row => ({
    statement_id: Number(row.STATEMENT_ID),
    type: v2String(row.STATEMENT_TYPE),
    title: v2String(row.TITLE),
    message: v2String(row.MESSAGE),
    policy_code: v2String(row.POLICY_CODE),
    status: v2String(row.STATUS),
    created_at: v2String(row.CREATED_AT),
    updated_at: v2String(row.UPDATED_AT)
  }));
  return v2Ok(data, 'success', v2PageMeta(page.page, page.page_size, Number(rows[0]?.TOTAL ?? 0)));
}

async function inTransaction<T>(connection: Connection, write: () => Promise<T>): Promise<T> {
  try {
    const result = await write();
    await connection.commit();
    return result;
  } catch (error) {
    try { await connection.rollback(); } catch { v2ServerError(); }
    throw error;
  }
}

async function update(connection: Connection, scope: ReturnType<typeof target>, status: string) {
  const count = await v2Execute(connection, contract.sql.update, { ...scope, status }, false);
  if (count === 0) v2NotFound('处置记录不存在');
  if (count !== 1) v2ServerError();
}

export async function v2PatchAccountStatement(event: H3Event, connection: Connection): Promise<V2Response<V2StatementStatusData>> {
  const scope = target(event);
  const { action } = await v2Body(event);
  const key = typeof action === 'string' ? action.trim() : '';
  if (!Object.hasOwn(contract.actions, key)) v2BadRequest('action 参数错误');
  const status = contract.actions[key as keyof typeof contract.actions];
  return inTransaction(connection, async () => {
    await update(connection, scope, status);
    const row = await v2One(connection, contract.sql.readStatus, scope);
    if (!row) v2ServerError();
    return v2Ok({ statement_id: Number(row.STATEMENT_ID), status: v2String(row.STATUS), updated_at: v2String(row.UPDATED_AT) });
  });
}

export async function v2CreateStatementAppeal(event: H3Event, connection: Connection): Promise<V2Response<V2StatementAppealData>> {
  const scope = target(event);
  const body = await v2Body(event);
  const message = typeof body.appeal_message === 'string' ? body.appeal_message.trim() : '';
  if (message === '') v2BadRequest('appeal_message 不能为空');
  if (Buffer.byteLength(message) > contract.maxAppealBytes || message.includes('\0')) v2BadRequest('appeal_message 参数错误');
  return inTransaction(connection, async () => {
    const statement = await v2One(connection, contract.sql.lock, scope);
    if (!statement) v2NotFound('处置记录不存在');
    const pending = await v2One(connection, contract.sql.pending, scope);
    let appealId: number;
    let status = v2String(statement.STATUS);
    if (pending) {
      if (v2String(pending.APPEAL_MESSAGE) !== message) v2Conflict('已有待处理申诉');
      appealId = Number(pending.APPEAL_ID);
    } else {
      appealId = Number((await v2One(connection, contract.sql.next))?.ID);
      if (!Number.isSafeInteger(appealId) || appealId < 1) v2ServerError();
      const count = await v2Execute(connection, contract.sql.insert, {
        ...scope, appeal_id: appealId, appeal_message: message
      }, false);
      if (count !== 1) v2ServerError();
      status = 'appealed';
      await update(connection, scope, status);
    }
    if (!Number.isSafeInteger(appealId) || appealId < 1) v2ServerError();
    return v2Ok({ statement_id: scope.statement_id, status, appeal_id: appealId, appeal_status: 'pending' });
  });
}
