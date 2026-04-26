import { v2CreateStatementAppeal } from '~/server/services/v2/users';
import { defineV2Handler, v2RouterNumber } from '~/server/utils/v2';

export default defineV2Handler((event, connection) =>
  v2CreateStatementAppeal(
    event,
    connection,
    v2RouterNumber(event, 'id')
  )
);
