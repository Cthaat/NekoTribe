import { setResponseHeader } from 'h3';
import { v2UploadMedia } from '~/server/services/v2/media';
import { safeAuthEntry } from '~/server/utils/auth-entry-errors';
import { defineV2Handler } from '~/server/utils/v2';

export default defineV2Handler(safeAuthEntry(async (event, connection) => {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  return v2UploadMedia(event, connection, true);
}));
