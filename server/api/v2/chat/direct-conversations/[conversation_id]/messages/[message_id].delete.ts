import { v2DeleteDirectMessage } from '~/server/services/v2/chat';
import { defineV2Handler, v2BadRequest, v2RouterParam } from '~/server/utils/v2';

export default defineV2Handler((event, connection) => {
  const id = (name: 'conversation_id' | 'message_id') => {
    const raw = v2RouterParam(event, name);
    const value = Number(raw);
    if (!/^[1-9][0-9]*$/.test(raw) || !Number.isSafeInteger(value)) v2BadRequest(`${name} 参数错误`);
    return value;
  };
  return v2DeleteDirectMessage(event, connection, id('conversation_id'), id('message_id'));
});
