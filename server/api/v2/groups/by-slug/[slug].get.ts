import { v2GetGroupBySlug } from '~/server/services/v2/groups';
import { setResponseHeader } from 'h3';
import { defineV2Handler, v2BadRequest, v2RouterParam } from '~/server/utils/v2';

export default defineV2Handler((event, connection) => {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const raw = v2RouterParam(event, 'slug');
  let slug: string;
  try { slug = decodeURIComponent(raw); }
  catch { v2BadRequest('slug 参数错误'); }
  return v2GetGroupBySlug(event, connection, slug);
});
