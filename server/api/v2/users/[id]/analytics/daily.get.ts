import { v2GetUserDailyAnalytics } from '~/server/services/v2/users';
import { defineV2Handler, v2RouterNumber } from '~/server/utils/v2';

export default defineV2Handler((event, connection) =>
  v2GetUserDailyAnalytics(
    event,
    connection,
    v2RouterNumber(event, 'id')
  )
);
