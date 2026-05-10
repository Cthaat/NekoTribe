import { v2CreateChatChannel } from '~/server/services/v2/chat';
import {
  defineV2Handler,
  v2RouterNumber
} from '~/server/utils/v2';

export default defineV2Handler((event, connection) =>
  v2CreateChatChannel(
    event,
    connection,
    v2RouterNumber(event, 'id')
  )
);
