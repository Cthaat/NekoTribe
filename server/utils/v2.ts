import type { H3Event } from 'h3';
import {
  createError,
  defineEventHandler,
  getQuery,
  getRouterParam,
  readBody
} from 'h3';
import oracledb from 'oracledb';
import {
  invalidateApiResponseCache,
  readApiResponseCache,
  shouldInvalidateApiResponseCache,
  writeApiResponseCache
} from './api-cache';
import {
  getRequestLogContext,
  logError,
  logInfo,
  serializeLogError
} from './logging';
import { getClientIp } from './client-ip';

export type V2DbRecord = Record<string, unknown>;
export type V2RouteHandler<T> = (
  event: H3Event,
  connection: oracledb.Connection
) => Promise<V2Response<T>>;

interface V2EventContext {
  getOracleConnection: () => Promise<oracledb.Connection>;
  auth?: V2AuthPayload;
}

interface V2PageState {
  page: number;
  page_size: number;
  start: number;
  end: number;
}

export function v2Ok<T>(
  data: T,
  message = 'success',
  meta: V2Meta | null = null
): V2Response<T> {
  return {
    code: 200,
    message,
    data,
    meta
  };
}

export function defineV2Handler<T>(
  handler: V2RouteHandler<T>
) {
  return defineEventHandler(
    async (event): Promise<V2Response<T>> => {
      const context = getRequestLogContext(event);
      const startAt = Date.now();
      const auth = v2OptionalAuth(event);

      logInfo('v2:handler:start', {
        requestId: context?.requestId ?? 'unknown',
        method:
          context?.method ||
          event.node.req.method ||
          'UNKNOWN',
        path: context?.path ?? event.path,
        query: context?.query ?? {},
        authUserId: auth?.userId ?? null
      });

      try {
        const cached = await readApiResponseCache<
          V2Response<T>
        >(event, 'v2');
        if (cached.status === 'hit') {
          logInfo('v2:handler:cache_hit', {
            requestId: context?.requestId ?? 'unknown',
            path: context?.path ?? event.path,
            cacheId: cached.context.cacheId,
            tags: cached.context.tags,
            durationMs: Date.now() - startAt
          });
          return cached.value;
        }

        const response = await v2WithConnection(
          event,
          connection => handler(event, connection)
        );
        if (
          cached.status === 'miss' &&
          response.code >= 200 &&
          response.code < 300
        ) {
          await writeApiResponseCache(
            event,
            cached.context,
            response
          );
        }
        if (
          response.code >= 200 &&
          response.code < 300 &&
          shouldInvalidateApiResponseCache(event)
        ) {
          await invalidateApiResponseCache(event, 'v2');
        }
        logInfo('v2:handler:success', {
          requestId: context?.requestId ?? 'unknown',
          path: context?.path ?? event.path,
          code: response.code,
          message: response.message,
          meta: response.meta,
          durationMs: Date.now() - startAt
        });
        return response;
      } catch (error) {
        logError('v2:handler:error', {
          requestId: context?.requestId ?? 'unknown',
          path: context?.path ?? event.path,
          durationMs: Date.now() - startAt,
          error: serializeLogError(error)
        });
        throw error;
      }
    }
  );
}

export function v2PageMeta(
  page: number,
  pageSize: number,
  total: number
): V2Meta {
  return {
    page,
    page_size: pageSize,
    total,
    has_next: page * pageSize < total
  };
}

export function v2Throw(
  statusCode: number,
  message: string,
  code = statusCode * 100 + 1
): never {
  throw createError({
    statusCode,
    message,
    data: {
      code,
      message,
      data: null,
      meta: null
    } satisfies V2Response<null>
  });
}

export function v2BadRequest(
  message = '请求参数错误'
): never {
  return v2Throw(400, message, 40001);
}

export function v2Unauthorized(
  message = '未认证或 token 无效'
): never {
  return v2Throw(401, message, 40101);
}

export function v2Forbidden(message = '权限不足'): never {
  return v2Throw(403, message, 40301);
}

export function v2NotFound(message = '资源不存在'): never {
  return v2Throw(404, message, 40401);
}

export function v2Conflict(message = '资源冲突'): never {
  return v2Throw(409, message, 40901);
}

export function v2Unprocessable(
  message = '业务规则不允许'
): never {
  return v2Throw(422, message, 42201);
}

export function v2ServerError(
  message = '服务器内部错误'
): never {
  return v2Throw(500, message, 50001);
}

export function v2Auth(event: H3Event): V2AuthPayload {
  const context =
    event.context as unknown as V2EventContext;
  if (!context.auth?.userId) {
    v2Unauthorized();
  }
  return context.auth;
}

export function v2OptionalAuth(
  event: H3Event
): V2AuthPayload | null {
  const context =
    event.context as unknown as V2EventContext;
  return context.auth ?? null;
}

export async function v2Connection(
  event: H3Event
): Promise<oracledb.Connection> {
  const context =
    event.context as unknown as V2EventContext;
  return await context.getOracleConnection();
}

export async function v2WithConnection<T>(
  event: H3Event,
  handler: (
    connection: oracledb.Connection
  ) => Promise<V2Response<T>>
): Promise<V2Response<T>> {
  const connection = await v2Connection(event);
  try {
    return await handler(connection);
  } finally {
    await connection.close();
  }
}

export async function v2Rows(
  connection: oracledb.Connection,
  sql: string,
  binds: oracledb.BindParameters = {}
): Promise<V2DbRecord[]> {
  const result = await connection.execute<V2DbRecord>(
    sql,
    binds,
    {
      outFormat: oracledb.OUT_FORMAT_OBJECT
    }
  );
  return result.rows ?? [];
}

export async function v2One(
  connection: oracledb.Connection,
  sql: string,
  binds: oracledb.BindParameters = {}
): Promise<V2DbRecord | null> {
  const rows = await v2Rows(connection, sql, binds);
  return rows[0] ?? null;
}

export async function v2Execute(
  connection: oracledb.Connection,
  sql: string,
  binds: oracledb.BindParameters = {},
  autoCommit = true
): Promise<number> {
  const result = await connection.execute(sql, binds, {
    autoCommit
  });
  return result.rowsAffected ?? 0;
}

export async function v2NextId(
  connection: oracledb.Connection,
  sequenceName: string
): Promise<number> {
  const row = await v2One(
    connection,
    `SELECT ${sequenceName}.NEXTVAL AS ID FROM dual`
  );
  if (!row) v2ServerError('序列生成失败');
  return v2Number(row.ID);
}

export async function v2Count(
  connection: oracledb.Connection,
  sql: string,
  binds: oracledb.BindParameters = {}
): Promise<number> {
  const row = await v2One(connection, sql, binds);
  return row ? v2Number(row.TOTAL) : 0;
}

export function v2Record(
  value: unknown
): Record<string, unknown> {
  if (
    value &&
    typeof value === 'object' &&
    !Array.isArray(value)
  ) {
    return value as Record<string, unknown>;
  }
  v2BadRequest('请求体必须是 JSON 对象');
}

export async function v2Body(
  event: H3Event
): Promise<Record<string, unknown>> {
  return v2Record(await readBody<unknown>(event));
}

export function v2String(
  value: unknown,
  fallback = ''
): string {
  if (typeof value === 'string') return value;
  if (
    typeof value === 'number' ||
    typeof value === 'boolean'
  ) {
    return String(value);
  }
  return fallback;
}

export function v2StringOrNull(
  value: unknown
): string | null {
  const result = v2String(value);
  return result.length > 0 ? result : null;
}

export function v2RequiredString(
  body: Record<string, unknown>,
  key: string
): string {
  const value = v2String(body[key]).trim();
  if (!value) v2BadRequest(`${key} 不能为空`);
  return value;
}

export function v2OptionalString(
  body: Record<string, unknown>,
  key: string
): string | undefined {
  const value = body[key];
  if (value === undefined || value === null)
    return undefined;
  return v2String(value);
}

export function v2Number(
  value: unknown,
  fallback = 0
): number {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === 'bigint') return Number(value);
  if (typeof value === 'string') {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : fallback;
  }
  return fallback;
}

export function v2NullableNumber(
  value: unknown
): number | null {
  if (
    value === null ||
    value === undefined ||
    value === ''
  ) {
    return null;
  }
  const parsed = v2Number(value, Number.NaN);
  return Number.isFinite(parsed) ? parsed : null;
}

export function v2RequiredNumber(
  value: unknown,
  name = 'id'
): number {
  const parsed = v2NullableNumber(value);
  if (!parsed || parsed <= 0)
    v2BadRequest(`${name} 参数错误`);
  return parsed;
}

export function v2RouterParam(
  event: H3Event,
  key: string
): string {
  const value = getRouterParam(event, key);
  if (!value) v2BadRequest(`${key} 参数错误`);
  return value;
}

export function v2RouterNumber(
  event: H3Event,
  key: string
): number {
  return v2RequiredNumber(v2RouterParam(event, key), key);
}

export function v2Boolean(value: unknown): boolean {
  if (typeof value === 'boolean') return value;
  if (typeof value === 'number') return value === 1;
  if (typeof value === 'string') {
    return ['1', 'true', 'yes'].includes(
      value.toLowerCase()
    );
  }
  return false;
}

export function v2BoolNumber(value: unknown): number {
  return v2Boolean(value) ? 1 : 0;
}

export function v2DateString(
  value: unknown
): string | null {
  if (value instanceof Date) return value.toISOString();
  const text = v2String(value);
  if (!text) return null;
  const date = new Date(text);
  return Number.isNaN(date.getTime())
    ? text
    : date.toISOString();
}

export function v2JsonValue(value: unknown): V2Json | null {
  if (
    value === null ||
    value === undefined ||
    value === ''
  ) {
    return null;
  }
  if (
    typeof value === 'string' ||
    typeof value === 'number' ||
    typeof value === 'boolean'
  ) {
    if (typeof value !== 'string') return value;
    try {
      return JSON.parse(value) as V2Json;
    } catch {
      return value;
    }
  }
  if (Array.isArray(value)) return value as V2Json[];
  if (typeof value === 'object') {
    return value as { [key: string]: V2Json };
  }
  return null;
}

export function v2StringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value
    .map(item => v2String(item).trim())
    .filter(item => item.length > 0);
}

export function v2NumberArray(value: unknown): number[] {
  if (!Array.isArray(value)) return [];
  return value
    .map(item => v2NullableNumber(item))
    .filter((item): item is number => item !== null);
}

export function v2QueryString(
  event: H3Event,
  key: string,
  fallback = ''
): string {
  const query = getQuery(event);
  return v2String(query[key], fallback);
}

export function v2QueryNumber(
  event: H3Event,
  key: string,
  fallback: number
): number {
  const query = getQuery(event);
  const parsed = v2Number(query[key], fallback);
  return parsed > 0 ? parsed : fallback;
}

export function v2Page(event: H3Event): V2PageState {
  const page = Math.min(
    Math.max(v2QueryNumber(event, 'page', 1), 1),
    10000
  );
  const pageSize = Math.min(
    Math.max(v2QueryNumber(event, 'page_size', 20), 1),
    100
  );
  return {
    page,
    page_size: pageSize,
    start: (page - 1) * pageSize + 1,
    end: page * pageSize
  };
}

export function v2RequestIp(event: H3Event): string {
  return getClientIp(event);
}

export function v2UserAgent(event: H3Event): string {
  return (
    event.node.req.headers['user-agent']?.toString() ||
    'unknown'
  );
}

export function v2Null(message: string): V2Response<null> {
  return v2Ok<null>(null, message);
}
