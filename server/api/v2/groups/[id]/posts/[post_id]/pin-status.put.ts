import { v2SetGroupPostPin } from '~/server/services/v2/groups';
import { defineV2Handler, v2RouterNumber } from '~/server/utils/v2';

export default defineV2Handler((event, connection) =>
  v2SetGroupPostPin(
    event,
    connection,
    v2RouterNumber(event, 'id'),
    v2RouterNumber(event, 'post_id')
  )
);
