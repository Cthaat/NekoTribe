import { v2GetMe } from '~/server/services/v2/users';
import { setResponseHeader } from 'h3';
import { defineV2Handler } from '~/server/utils/v2';
import { safeAuthEntry } from '~/server/utils/auth-entry-errors';

const handler = safeAuthEntry(v2GetMe);
export default defineV2Handler((event, connection) => {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  return handler(event, connection);
});
