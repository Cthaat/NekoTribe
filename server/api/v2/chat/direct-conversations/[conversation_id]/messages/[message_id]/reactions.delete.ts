import { v2SetDirectReaction } from '~/server/services/v2/chat';
import { defineV2Handler } from '~/server/utils/v2';

export default defineV2Handler((event, connection) => v2SetDirectReaction(event, connection, false));
