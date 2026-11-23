import { defineAiGenerationHandler } from '~/server/services/ai/stream-response';
import { createError, setResponseHeader } from 'h3';
import { safeV2Action } from '~/server/utils/auth-entry-errors';
import { AiQuotaError, throwAiQuotaResponse } from '~/server/utils/ai-model-quota';
import { v2Auth, v2BadRequest, v2Conflict, v2Ok, v2RouterParam } from '~/server/utils/v2';
import { generateWritingReply } from '~/server/services/ai/writing-service';
import { WritingTurnError } from '~/server/services/ai/writing-turn';
import { hasTooManyAiBodyMembers, isExpectedAiSequence, readBoundedAiBody } from '~/server/services/ai/knowledge-search-body';

async function readWritingRequest(event: Parameters<typeof v2Auth>[0]): Promise<{skillId: 'writing-draft' | null; expectedSequence?: number}> {
  try {
    const bytes = await readBoundedAiBody(event.node.req);
    if (bytes.length === 0) return {skillId:null};
    const raw = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes);
    const body: unknown = JSON.parse(raw);
    if (body && typeof body === 'object' && !Array.isArray(body)) {
      const keys = Object.keys(body);
      if (keys.some(key => key !== 'skill_id' && key !== 'expected_sequence') ||
          hasTooManyAiBodyMembers(raw, keys.length)) throw new Error();
      const entries = body as Record<string, unknown>;
      if (Object.hasOwn(entries,'skill_id') && entries.skill_id !== 'writing-draft') throw new Error();
      if (Object.hasOwn(entries,'expected_sequence')) {
        if (!isExpectedAiSequence(entries.expected_sequence)) throw new Error();
        return {skillId:entries.skill_id === 'writing-draft' ? entries.skill_id : null, expectedSequence:entries.expected_sequence};
      }
      return {skillId:entries.skill_id === 'writing-draft' ? entries.skill_id : null};
    }
  } catch { /* Invalid JSON and oversized input share the public error. */ }
  v2BadRequest('写作生成参数错误');
}

export default defineAiGenerationHandler(async event => {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  return safeV2Action(async () => {
    v2Auth(event);
    const controller=new AbortController();
    const cancel=()=>controller.abort();
    event.node?.req?.once('aborted',cancel);
    event.node?.res?.once('close',cancel);
    if(event.node?.req?.aborted || event.node?.res?.destroyed) cancel();
    try {
      const {skillId, expectedSequence} = await readWritingRequest(event);
      return v2Ok(await generateWritingReply(event,v2RouterParam(event,'id'),undefined,controller.signal,skillId,expectedSequence));
    } catch(error) {
      if (error instanceof AiQuotaError) throwAiQuotaResponse(event,error);
      if (error instanceof WritingTurnError && error.code === 'SEQUENCE_CONFLICT') v2Conflict('会话已变更，请刷新历史');
      if(error instanceof WritingTurnError || (error instanceof Error && ['SKILL_UNAVAILABLE','SKILL_CONFIG_UNAVAILABLE'].includes(error.message))) {
        if(error instanceof WritingTurnError && (error.code==='INVALID_CONTEXT' || error.code==='CONTEXT_TOO_LARGE')) v2BadRequest('写作会话上下文不可用');
        throw createError({statusCode:503,statusMessage:'Service temporarily unavailable',data:{code:50301,message:'服务暂不可用，请稍后重试。',data:null,meta:null}});
      }
      throw error;
    } finally {
      event.node?.req?.off('aborted',cancel);
      event.node?.res?.off('close',cancel);
    }
  });
});
