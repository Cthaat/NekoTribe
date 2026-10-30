import { listOwned } from '~/server/services/ai/conversation-http';
import { privateAiHandler } from '~/server/services/ai/private-http';
export default privateAiHandler(listOwned);
