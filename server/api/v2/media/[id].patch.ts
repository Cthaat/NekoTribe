import { updateMediaAltText } from '~/server/services/ai/vision-media';
import { privateAiHandler } from '~/server/services/ai/private-http';

export default privateAiHandler(updateMediaAltText);
