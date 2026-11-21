import {
  getHeader,
  getRouterParam,
  sendStream,
  setResponseHeader,
  setResponseStatus,
  type H3Event
} from 'h3';
import { getStorageProvider } from '~/server/storage';
import { StorageHttpError } from '~/server/storage/http';
import { normalizeLocalStorageKey } from '~/server/storage/local-path';
import { v2Auth, v2BadRequest, v2Connection, v2NotFound, v2One, v2ServerError, v2Throw } from '~/server/utils/v2';
import { query } from '../../../specifications/requirements/media-private-read.json';

async function authorizedStorageKey(event: H3Event, viewerId: number, mediaId: number): Promise<string> {
  let row;
  try {
    const connection = await v2Connection(event);
    try {
      row = await v2One(connection, query, { viewer_id: viewerId, media_id: mediaId });
    } finally {
      await connection.close();
    }
  } catch (error) {
    if (typeof error === 'object' && error !== null && (
      ('errorNum' in error && (error.errorNum === 904 || error.errorNum === 942)) ||
      ('code' in error && (error.code === 'ORA-00904' || error.code === 'ORA-00942'))
    )) {
      v2Throw(503, '媒体存储暂不可用');
    }
    v2ServerError();
  }

  const scope = row?.ACCESS_SCOPE;
  if ((scope !== 'chat' && scope !== 'post') || typeof row?.STORAGE_KEY !== 'string') {
    v2NotFound('媒体不存在');
  }
  let key;
  try {
    key = normalizeLocalStorageKey(row.STORAGE_KEY);
  } catch {
    v2NotFound('媒体不存在');
  }
  if (!key.startsWith(`private/${scope}/`)) v2NotFound('媒体不存在');
  return key;
}

export async function readPrivateMediaContent(event: H3Event) {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  setResponseHeader(event, 'X-Content-Type-Options', 'nosniff');
  const { userId } = v2Auth(event);
  const rawId = getRouterParam(event, 'id', { decode: true }) ?? '';
  const mediaId = Number(rawId);
  if (!/^[1-9][0-9]*$/.test(rawId) || !Number.isSafeInteger(mediaId)) v2BadRequest('id 参数错误');

  const key = await authorizedStorageKey(event, userId, mediaId);
  let result;
  try {
    result = await getStorageProvider().readPrivateObject(key, {
      headOnly: event.method === 'HEAD',
      rangeHeader: getHeader(event, 'range')
    });
  } catch (error) {
    if (error instanceof StorageHttpError) {
      if ([400, 404].includes(error.statusCode)) v2NotFound('媒体不存在');
      if (error.statusCode === 416) {
        const range = error.headers['Content-Range'];
        if (range) setResponseHeader(event, 'Content-Range', range);
        v2Throw(416, '请求范围无效');
      }
      if (error.statusCode === 503) v2Throw(503, '媒体存储暂不可用');
    }
    v2ServerError();
  }
  setResponseStatus(event, result.statusCode);
  for (const name of ['Accept-Ranges', 'Content-Length', 'Content-Range']) {
    const value = result.headers[name];
    if (value !== undefined) setResponseHeader(event, name, value);
  }
  setResponseHeader(event, 'Content-Type', 'application/octet-stream');
  setResponseHeader(event, 'Content-Disposition', 'attachment');
  return sendStream(event, result.stream);
}
