import { v2CompleteTwoFactorLogin } from '~/server/services/v2/auth';
import {
  defineV2Handler,
  v2RouterParam
} from '~/server/utils/v2';
import { safeAuthEntry } from '~/server/utils/auth-entry-errors';

export default defineV2Handler(safeAuthEntry((event, connection) =>
  v2CompleteTwoFactorLogin(
    event,
    connection,
    v2RouterParam(event, 'id')
  )
));
