import { v2ListPosts } from '~/server/services/v2/posts';
import { defineV2Handler } from '~/server/utils/v2';

export default defineV2Handler((event, connection) =>
  v2ListPosts(event, connection, { mode: 'bookmarks' })
);
