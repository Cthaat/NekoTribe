import { v2ListPosts } from '~/server/services/v2/posts';
import {
  defineV2Handler
} from '~/server/utils/v2';
import { v2SafeRouterId } from '~/server/utils/router-id';
import { safeAuthEntry } from '~/server/utils/auth-entry-errors';

export default defineV2Handler(safeAuthEntry((event, connection) =>
  v2ListPosts(event, connection, {
    mode: 'retweets',
    post_id: v2SafeRouterId(event, 'id')
  })
));
