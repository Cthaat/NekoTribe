import { v2CreateGroupInvite } from '~/server/services/v2/groups';
import {
  defineV2Handler,
  v2RouterNumber
} from '~/server/utils/v2';

export default defineV2Handler((event, connection) =>
  v2CreateGroupInvite(
    event,
    connection,
    v2RouterNumber(event, 'id')
  )
);
