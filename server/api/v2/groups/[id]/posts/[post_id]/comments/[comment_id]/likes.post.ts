import { v2LikeGroupComment } from '~/server/services/v2/groups';
import { defineV2Handler } from '~/server/utils/v2';

export default defineV2Handler((event, connection) =>
  v2LikeGroupComment(event, connection, true)
);
