import { v2TagAnalytics } from '~/server/services/v2/posts';
import { getRouterParam, setResponseHeader } from 'h3';
import { defineV2Handler, v2BadRequest } from '~/server/utils/v2';
import { safeAuthEntry } from '~/server/utils/auth-entry-errors';

export default defineV2Handler(safeAuthEntry((event, connection) => {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const name = getRouterParam(event, 'name', { decode: true });
  if (!name) v2BadRequest('name 参数错误');
  return v2TagAnalytics(event, connection, name);
}));
