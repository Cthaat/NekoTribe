import { v2VotePostPoll } from '~/server/services/v2/post-poll-http';
import { defineV2Handler } from '~/server/utils/v2';

export default defineV2Handler((event, connection) => v2VotePostPoll(event, connection, 'group'));
