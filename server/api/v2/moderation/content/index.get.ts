import { v2ListModerationContent } from '~/server/services/v2/moderation';
import { safeAuthEntry } from '~/server/utils/auth-entry-errors';
import { defineV2Handler } from '~/server/utils/v2';

export default defineV2Handler(safeAuthEntry(v2ListModerationContent));
