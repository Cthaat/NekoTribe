import { v2ListPosts } from '~/server/services/v2/posts';
import { defineV2Handler, v2RouterParam } from '~/server/utils/v2';

export default defineV2Handler((event, connection) =>
  v2ListPosts(event, connection, {
    mode: 'tag',
    tag_name: v2RouterParam(event, 'name')
  })
);
