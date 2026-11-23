import { v2ReadPostPoll } from '~/server/services/v2/post-poll-http';
import { defineV2Handler } from '~/server/utils/v2';

export default defineV2Handler((event, connection) => v2ReadPostPoll(event, connection, 'group'));
