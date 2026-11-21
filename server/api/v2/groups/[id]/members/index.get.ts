import { v2GroupMembers } from '~/server/services/v2/groups';
import { setResponseHeader } from 'h3';
import {
  defineV2Handler,
  v2Auth,
  v2BadRequest,
  v2RouterParam
} from '~/server/utils/v2';

export default defineV2Handler((event, connection) => {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  v2Auth(event);
  let raw: string;
  try { raw = decodeURIComponent(v2RouterParam(event, 'id')); }
  catch { v2BadRequest('id 参数错误'); }
  const id = Number(raw);
  if (!/^[1-9][0-9]*$/.test(raw) || !Number.isSafeInteger(id)) v2BadRequest('id 参数错误');
  return v2GroupMembers(event, connection, id);
});
