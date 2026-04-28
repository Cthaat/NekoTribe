import { v2ChangeEmail } from '~/server/services/v2/users';
import { defineV2Handler } from '~/server/utils/v2';

export default defineV2Handler(v2ChangeEmail);
