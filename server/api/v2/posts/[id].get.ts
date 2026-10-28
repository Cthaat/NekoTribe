import { getRouterParam, setResponseHeader } from 'h3';
import { v2GetPost } from '~/server/services/v2/posts';
import { defineV2Handler, v2BadRequest } from '~/server/utils/v2';
import { safeAuthEntry } from '~/server/utils/auth-entry-errors';

const handler = safeAuthEntry((event, connection) => {
  const raw = getRouterParam(event, 'id') ?? '';
  const id = Number(raw);
  if (!/^[1-9][0-9]*$/.test(raw) || !Number.isSafeInteger(id)) v2BadRequest('id 参数错误');
  return v2GetPost(event, connection, id);
});

export default defineV2Handler((event, connection) => {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  return handler(event, connection);
});
