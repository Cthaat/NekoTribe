import { createError, defineEventHandler, setResponseHeader } from 'h3';
import { safeV2Action } from '~/server/utils/auth-entry-errors';
import { v2Auth, v2BadRequest, v2Ok, v2RouterParam } from '~/server/utils/v2';
import { generateWritingReply } from '~/server/services/ai/writing-service';
import { WritingTurnError } from '~/server/services/ai/writing-turn';

export default defineEventHandler(async event => {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  return safeV2Action(async () => {
    v2Auth(event);
    const controller=new AbortController();
    const cancel=()=>controller.abort();
    event.node?.req?.once('aborted',cancel);
    event.node?.res?.once('close',cancel);
    if(event.node?.req?.aborted || event.node?.res?.destroyed) cancel();
    try {
      return v2Ok(await generateWritingReply(event,v2RouterParam(event,'id'),undefined,controller.signal));
    } catch(error) {
      if(error instanceof WritingTurnError) {
        if(error.code==='INVALID_CONTEXT' || error.code==='CONTEXT_TOO_LARGE') v2BadRequest('写作会话上下文不可用');
        throw createError({statusCode:503,statusMessage:'Service temporarily unavailable',data:{code:50301,message:'服务暂不可用，请稍后重试。',data:null,meta:null}});
      }
      throw error;
    } finally {
      event.node?.req?.off('aborted',cancel);
      event.node?.res?.off('close',cancel);
    }
  });
});
