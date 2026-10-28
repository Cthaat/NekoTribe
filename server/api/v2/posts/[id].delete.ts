import { v2DeletePost } from '~/server/services/v2/posts';
import { defineV2Handler } from '~/server/utils/v2';
import { v2SafeRouterId } from '~/server/utils/router-id';
import { safeAuthEntry } from '~/server/utils/auth-entry-errors';
import { setResponseHeader } from 'h3';

export default defineV2Handler(safeAuthEntry(async (event, connection) => {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  return await v2DeletePost(event, connection, v2SafeRouterId(event, 'id'));
}));
