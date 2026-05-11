import { v2GetModerationStats } from '~/server/services/v2/moderation';
import { defineV2Handler } from '~/server/utils/v2';

export default defineV2Handler(v2GetModerationStats);
