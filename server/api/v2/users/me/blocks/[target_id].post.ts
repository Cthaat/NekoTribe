import { v2BlockUser } from '~/server/services/v2/users';
import {
  defineV2Handler,
  v2RouterNumber
} from '~/server/utils/v2';

export default defineV2Handler((event, connection) =>
  v2BlockUser(
    event,
    connection,
    v2RouterNumber(event, 'target_id')
  )
);
