import { v2PatchModerationAppeal } from '~/server/services/v2/moderation-appeals';
import { safeAuthEntry } from '~/server/utils/auth-entry-errors';
import { defineV2Handler } from '~/server/utils/v2';

export default defineV2Handler(safeAuthEntry(v2PatchModerationAppeal));
