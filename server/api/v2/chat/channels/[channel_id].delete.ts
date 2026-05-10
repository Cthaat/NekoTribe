import { v2DeleteChatChannel } from '~/server/services/v2/chat';
import {
  defineV2Handler,
  v2RouterNumber
} from '~/server/utils/v2';

export default defineV2Handler((event, connection) =>
  v2DeleteChatChannel(
    event,
    connection,
    v2RouterNumber(event, 'channel_id')
  )
);
