import { v2ModerateUser } from '~/server/services/v2/moderation-user-actions';
import { safeAuthEntry } from '~/server/utils/auth-entry-errors';
import { defineV2Handler } from '~/server/utils/v2';

export default defineV2Handler(safeAuthEntry(v2ModerateUser));
