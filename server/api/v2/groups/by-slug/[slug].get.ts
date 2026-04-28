import { v2GetGroupBySlug } from '~/server/services/v2/groups';
import { defineV2Handler, v2RouterParam } from '~/server/utils/v2';

export default defineV2Handler((event, connection) =>
  v2GetGroupBySlug(event, connection, v2RouterParam(event, 'slug'))
);
