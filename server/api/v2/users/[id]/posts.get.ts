import { v2ListPosts } from '~/server/services/v2/posts';
import { defineV2Handler, v2RouterNumber } from '~/server/utils/v2';

export default defineV2Handler((event, connection) =>
  v2ListPosts(event, connection, {
    mode: 'user',
    user_id: v2RouterNumber(event, 'id')
  })
);
