import { v2SearchTags } from '~/server/services/v2/posts';
import { defineV2Handler } from '~/server/utils/v2';
import { safeAuthEntry } from '~/server/utils/auth-entry-errors';

export default defineV2Handler(safeAuthEntry(v2SearchTags));
