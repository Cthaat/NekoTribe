import { v2CompleteTwoFactorLogin } from '~/server/services/v2/auth';
import {
  defineV2Handler,
  v2RouterParam
} from '~/server/utils/v2';

export default defineV2Handler((event, connection) =>
  v2CompleteTwoFactorLogin(
    event,
    connection,
    v2RouterParam(event, 'id')
  )
);
