import { v2PostDraftRequest } from '~/server/services/v2/post-drafts';
import { defineV2Handler } from '~/server/utils/v2';

export default defineV2Handler((event, connection) => v2PostDraftRequest(event, connection, 'create'));
