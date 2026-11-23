import { v2ProfilePin } from '~/server/services/v2/profile-pinned-post';
import { defineV2Handler } from '~/server/utils/v2';

export default defineV2Handler((event, connection) => v2ProfilePin(event, connection, 'clear'));
