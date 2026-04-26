import { v2CreateGroupPost } from '~/server/services/v2/groups';
import { defineV2Handler, v2RouterNumber } from '~/server/utils/v2';

export default defineV2Handler((event, connection) =>
  v2CreateGroupPost(event, connection, v2RouterNumber(event, 'id'))
);
