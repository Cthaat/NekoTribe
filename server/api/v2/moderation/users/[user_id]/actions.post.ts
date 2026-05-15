import { v2ModerateUser } from '~/server/services/v2/moderation';
import { defineV2Handler, v2RouterNumber } from '~/server/utils/v2';

export default defineV2Handler((event, connection) =>
  v2ModerateUser(
    event,
    connection,
    v2RouterNumber(event, 'user_id')
  )
);
