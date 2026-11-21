import { defineEventHandler, setResponseHeader } from 'h3';
import { v2Auth, v2BadRequest, v2Connection, v2NotFound, v2Ok, v2RouterParam } from '~/server/utils/v2';
import { saveModerationFeedback, validId } from '~/server/services/ai/conversation-store';
import { feedbackUnavailable, parseModerationFeedback } from '~/server/services/ai/moderation-feedback';
import { readBoundedAiBody } from '~/server/services/ai/knowledge-search-body';
import { safeV2Action } from '~/server/utils/auth-entry-errors';

export default defineEventHandler(event => {
  setResponseHeader(event,'Cache-Control','private, no-store');
  return safeV2Action(async () => {
    v2Auth(event);
    const id = v2RouterParam(event,'id');
    const messageId = v2RouterParam(event,'message_id');
    if (!validId(id) || !validId(messageId)) v2NotFound('会话不存在');
    const body = await readBoundedAiBody(event.node.req).catch(() => v2BadRequest('审核反馈参数错误'));
    const rating = parseModerationFeedback(body);
    const connection = await v2Connection(event).catch(feedbackUnavailable);
    try {
      return v2Ok(await saveModerationFeedback(event, connection, id, messageId, rating));
    } finally {
      await connection.close().catch(feedbackUnavailable);
    }
  });
});
