import { createError, defineEventHandler, setResponseHeader } from 'h3';
import { generateGroupDraft, GroupDraftUnavailable, parseGroupDraftRequest } from '~/server/services/ai/group-draft';
import { readBoundedAiBody } from '~/server/services/ai/knowledge-search-body';
import { safeV2Action } from '~/server/utils/auth-entry-errors';
import { AiQuotaError, throwAiQuotaResponse } from '~/server/utils/ai-model-quota';
import { v2Auth, v2BadRequest, v2Forbidden, v2Ok, v2RouterParam } from '~/server/utils/v2';

export default defineEventHandler(event => {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  return safeV2Action(async () => {
    v2Auth(event);
    const controller = new AbortController();
    const cancel = () => controller.abort();
    const {req, res} = event.node;
    req.once('aborted', cancel);
    res.once('close', cancel);
    if (req.aborted || res.destroyed) cancel();
    try {
      let bytes: Buffer;
      try { bytes = await readBoundedAiBody(req); }
      catch { v2BadRequest('群运营草稿参数错误'); }
      const request = parseGroupDraftRequest(bytes);
      return v2Ok(await generateGroupDraft(event, v2RouterParam(event, 'id'), request, controller.signal));
    } catch (error) {
      if (error instanceof AiQuotaError) throwAiQuotaResponse(event, error);
      if (controller.signal.aborted || error instanceof GroupDraftUnavailable ||
          (error instanceof Error && ['SKILL_UNAVAILABLE','SKILL_CONFIG_UNAVAILABLE'].includes(error.message))) {
        throw createError({statusCode:503,statusMessage:'Service temporarily unavailable',
          data:{code:50301,message:'服务暂不可用，请稍后重试。',data:null,meta:null}});
      }
      if (typeof error === 'object' && error !== null && 'statusCode' in error && error.statusCode === 403) {
        v2Forbidden();
      }
      throw error;
    } finally {
      req.off('aborted', cancel);
      res.off('close', cancel);
    }
  });
});
