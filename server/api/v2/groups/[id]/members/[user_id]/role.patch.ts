import { v2ChangeMemberRole } from '~/server/services/v2/groups';
import { defineV2Handler, v2RouterNumber } from '~/server/utils/v2';

export default defineV2Handler((event, connection) =>
  v2ChangeMemberRole(
    event,
    connection,
    v2RouterNumber(event, 'id'),
    v2RouterNumber(event, 'user_id')
  )
);
