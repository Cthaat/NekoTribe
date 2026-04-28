import { v2CreatePost } from '~/server/services/v2/posts';
import { defineV2Handler } from '~/server/utils/v2';

export default defineV2Handler(v2CreatePost);
