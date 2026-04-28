import { v2TagAnalytics } from '~/server/services/v2/posts';
import { defineV2Handler, v2RouterParam } from '~/server/utils/v2';

export default defineV2Handler((event, connection) =>
  v2TagAnalytics(event, connection, v2RouterParam(event, 'name'))
);
