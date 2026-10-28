import { v2LikePost } from '~/server/services/v2/posts';
import { defineV2Handler } from '~/server/utils/v2';
import { v2SafeRouterId } from '~/server/utils/router-id';
import { safeAuthEntry } from '~/server/utils/auth-entry-errors';

export default defineV2Handler(safeAuthEntry((event, connection) =>
  v2LikePost(event, connection, v2SafeRouterId(event, 'id'), true)
));
