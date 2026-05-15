import { v2PatchModerationAppeal } from '~/server/services/v2/moderation';
import { defineV2Handler, v2RouterNumber } from '~/server/utils/v2';

export default defineV2Handler((event, connection) =>
  v2PatchModerationAppeal(
    event,
    connection,
    v2RouterNumber(event, 'appeal_id')
  )
);
