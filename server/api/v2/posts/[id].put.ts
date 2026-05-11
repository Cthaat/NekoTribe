import { v2UpdatePost } from '~/server/services/v2/posts';
import { defineV2Handler, v2RouterNumber } from '~/server/utils/v2';

export default defineV2Handler((event, connection) =>
  v2UpdatePost(event, connection, v2RouterNumber(event, 'id'))
);
