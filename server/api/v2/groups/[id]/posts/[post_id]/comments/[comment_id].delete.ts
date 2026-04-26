import { v2DeleteGroupComment } from '~/server/services/v2/groups';
import { defineV2Handler, v2RouterNumber } from '~/server/utils/v2';

export default defineV2Handler((event, connection) =>
  v2DeleteGroupComment(
    event,
    connection,
    v2RouterNumber(event, 'comment_id')
  )
);
