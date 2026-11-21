import { setResponseHeader } from 'h3';
import { v2PopularGroups } from '~/server/services/v2/groups';
import { defineV2Handler } from '~/server/utils/v2';

export default defineV2Handler((event, connection) => {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  return v2PopularGroups(event, connection);
});
