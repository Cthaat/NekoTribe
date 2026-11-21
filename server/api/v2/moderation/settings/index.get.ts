import { safeAuthEntry } from '~/server/utils/auth-entry-errors';
import { v2GetModerationSettings } from '~/server/services/v2/moderation-dashboard';
import { defineV2Handler } from '~/server/utils/v2';

export default defineV2Handler(safeAuthEntry(v2GetModerationSettings));
