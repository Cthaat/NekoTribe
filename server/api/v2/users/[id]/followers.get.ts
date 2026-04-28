import { v2RelationshipList } from '~/server/services/v2/users';
import {
  defineV2Handler,
  v2RouterNumber
} from '~/server/utils/v2';

export default defineV2Handler((event, connection) =>
  v2RelationshipList(
    event,
    connection,
    'followers',
    v2RouterNumber(event, 'id')
  )
);
