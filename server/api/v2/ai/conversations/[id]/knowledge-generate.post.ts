import { defineAiGenerationHandler } from '~/server/services/ai/stream-response';
import {createError,setResponseHeader} from 'h3';
import {safeV2Action} from '~/server/utils/auth-entry-errors';
import {AiQuotaError,throwAiQuotaResponse} from '~/server/utils/ai-model-quota';
import {v2Auth,v2BadRequest,v2Conflict,v2Ok,v2RouterParam} from '~/server/utils/v2';
import {generateKnowledgeConversation,KnowledgeConversationError} from '~/server/services/ai/knowledge-conversation-service';
import {KnowledgeServiceError} from '~/server/services/ai/knowledge-service';
import {KnowledgeCitationError} from '~/server/services/ai/knowledge-citations';
import {KnowledgeTurnError} from '~/server/services/ai/knowledge-turn';
import {readKnowledgeSearchBody} from '~/server/services/ai/knowledge-search-body';

export default defineAiGenerationHandler(async event=>{
  setResponseHeader(event,'Cache-Control','private, no-store');
  return safeV2Action(async()=>{
    v2Auth(event);
    const controller=new AbortController();const cancel=()=>controller.abort();
    event.node?.req?.once('aborted',cancel);event.node?.res?.once('close',cancel);
    if(event.node?.req?.aborted || event.node?.res?.destroyed) cancel();
    try {
      let input: Awaited<ReturnType<typeof readKnowledgeSearchBody>>;
      try {input=await readKnowledgeSearchBody(event.node.req);} catch {v2BadRequest('知识检索参数错误');}
      const result=await generateKnowledgeConversation(event,v2RouterParam(event,'id'),undefined,controller.signal,input.phrase,input.skillId,input.expectedSequence);
      return 'message' in result ? v2Ok({status:'insufficient_evidence',message:null}) : v2Ok({status:'generated',message:result});
    } catch(error) {
      if(error instanceof AiQuotaError) throwAiQuotaResponse(event,error);
      if(error instanceof KnowledgeConversationError && error.code==='SEQUENCE_CONFLICT') v2Conflict('会话已变更，请刷新历史');
      if(error instanceof KnowledgeConversationError && error.code==='INVALID_CONTEXT') v2BadRequest('知识会话上下文不可用');
      if(error instanceof KnowledgeServiceError && (error.code==='CONTEXT_TOO_LARGE' || error.code==='INVALID_CONTEXT')) v2BadRequest('知识会话上下文不可用');
      if(error instanceof KnowledgeConversationError || error instanceof KnowledgeServiceError || error instanceof KnowledgeCitationError || error instanceof KnowledgeTurnError ||
        (error instanceof Error && ['SKILL_UNAVAILABLE','SKILL_CONFIG_UNAVAILABLE'].includes(error.message))) {
        throw createError({statusCode:503,statusMessage:'Service temporarily unavailable',data:{code:50301,message:'服务暂不可用，请稍后重试。',data:null,meta:null}});
      }
      throw error;
    } finally {event.node?.req?.off('aborted',cancel);event.node?.res?.off('close',cancel);}
  });
});
