import { v2RestoreNotification } from '~/server/services/v2/notifications';
import {
  defineV2Handler,
  v2RouterNumber
} from '~/server/utils/v2';

export default defineV2Handler((event, connection) =>
  v2RestoreNotification(
    event,
    connection,
    v2RouterNumber(event, 'id')
  )
);
