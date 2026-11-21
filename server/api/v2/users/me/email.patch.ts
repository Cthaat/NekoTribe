import { v2ChangeEmail } from '~/server/services/v2/users';
import { defineV2Handler } from '~/server/utils/v2';
import { safeAuthEntry } from '~/server/utils/auth-entry-errors';

export default defineV2Handler(safeAuthEntry(v2ChangeEmail));
