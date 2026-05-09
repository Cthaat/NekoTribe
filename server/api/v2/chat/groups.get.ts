import { v2ListChatGroups } from '~/server/services/v2/chat';
import { defineV2Handler } from '~/server/utils/v2';

export default defineV2Handler(v2ListChatGroups);
