import { v2WriteFollow } from '~/server/services/v2/user-visibility';
import { safeAuthEntry } from '~/server/utils/auth-entry-errors';
import { defineV2Handler } from '~/server/utils/v2';

export default defineV2Handler(safeAuthEntry((event, connection) =>
  v2WriteFollow(event, connection, false)
));
