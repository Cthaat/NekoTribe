import { setResponseHeader } from 'h3';
import { v2UpdateChatChannel } from '~/server/services/v2/chat';
import { defineV2Handler, v2BadRequest, v2RouterParam } from '~/server/utils/v2';

export default defineV2Handler((event, connection) => {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const raw = v2RouterParam(event, 'channel_id');
  const id = Number(raw);
  if (!/^[1-9][0-9]*$/.test(raw) || !Number.isSafeInteger(id)) v2BadRequest('id 参数错误');
  return v2UpdateChatChannel(event, connection, id);
});
