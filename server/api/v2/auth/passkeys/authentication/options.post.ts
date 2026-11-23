import { v2PasskeyOptions } from '~/server/services/v2/passkey-auth';
import { defineV2Handler } from '~/server/utils/v2';
import { safeAuthEntry } from '~/server/utils/auth-entry-errors';

export default defineV2Handler(safeAuthEntry((event, connection) => v2PasskeyOptions(event, connection, 'login')));
