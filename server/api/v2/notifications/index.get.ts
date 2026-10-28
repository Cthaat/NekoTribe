import { setResponseHeader } from 'h3';
import { v2ListNotifications } from '~/server/services/v2/notifications';
import { defineV2Handler } from '~/server/utils/v2';
import { safeAuthEntry } from '~/server/utils/auth-entry-errors';

export default defineV2Handler(safeAuthEntry(async (event, connection) => {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  return await v2ListNotifications(event, connection);
}));
