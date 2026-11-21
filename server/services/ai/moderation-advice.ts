import type { H3Event } from 'h3';
import type { Connection } from 'oracledb';
import { v2Auth, v2BadRequest, v2Conflict, v2Connection, v2One } from '~/server/utils/v2';
import { AiQuotaError, requireAiModelQuota } from '~/server/utils/ai-model-quota';
import { AiRunAudit } from './run-audit';
import { appendModerationAdvice, readConversation } from './conversation-store';
import { AiInferenceTransport } from './inference-transport';
import type { AiModelRouter } from './model-configuration';
import { configuredModelRouter } from './model-source';
import { moderationPrompt, moderationResponseSchema, ModerationAdviceUnavailable, parseModelAdvice,
  readModerationMaterial, type ModerationRequest } from './moderation-advice-record';
import { selectConfiguredConversationSkill } from './skill-conversation';

async function withConnection<T>(event:H3Event, action:(connection:Connection)=>Promise<T>):Promise<T> {
  const connection = await v2Connection(event);
  try {return await action(connection);}
  finally {await connection.close();}
}

export async function generateModerationAdvice(event:H3Event,id:string,request:ModerationRequest,signal:AbortSignal) {
  const actor = v2Auth(event);
  signal.throwIfAborted();
  const loaded = await withConnection(event,async connection=>{
    const conversation = await readConversation(event,connection,id);
    if (conversation.purpose !== 'moderation') v2BadRequest('审核建议参数错误');
    const sequence = await v2One(connection,'SELECT NVL(MAX(sequence_no),0) AS last_sequence FROM n_ai_messages WHERE conversation_id=:conversation_id',{conversation_id:id});
    if (sequence?.LAST_SEQUENCE !== request.expected_sequence) v2Conflict('会话已变更，请重试');
    const skill = await selectConfiguredConversationSkill(event,connection,{
      ownerUserId:actor.userId,purpose:'moderation',groupId:null
    },request.skill_id ?? null);
    return {material:await readModerationMaterial(event,connection,request),generation:skill.configGeneration};
  });
  const audit = new AiRunAudit('moderation_advice', loaded.generation, request.skill_id ? 'explicit' : 'purpose-default');
  try {
    const result = await generateApprovedAdvice(event,id,request,signal,actor.userId,loaded,audit);
    audit.finish(result.status);
    return result;
  } catch (error) {
    audit.fail(error, signal);
    throw error;
  }
}

async function generateApprovedAdvice(
  event: H3Event, id: string, request: ModerationRequest, signal: AbortSignal, actor: number,
  {material,generation}: {material: Awaited<ReturnType<typeof readModerationMaterial>>; generation: number},
  audit: AiRunAudit,
) {
  signal.throwIfAborted();
  if (!material) return {status:'insufficient_evidence',message:null} as const;
  let selection: ReturnType<AiModelRouter['select']>;
  let advice: ReturnType<typeof parseModelAdvice>;
  audit.stage = 'configuration';
  try {
    selection = (await configuredModelRouter()).select('moderation',['structured-output']);
    audit.configRevision = selection.configurationRevision;
    const prompt = JSON.stringify({target_type:request.target_type,locale:request.locale,content:material.content,rules:material.rules});
    const budget = Math.min(16384,selection.contextWindowTokens-selection.maxOutputTokens-512);
    if (Buffer.byteLength(moderationPrompt)+Buffer.byteLength(prompt)+Buffer.byteLength(JSON.stringify(moderationResponseSchema))+64 > budget) throw new Error();
    const transport = new AiInferenceTransport(reference => process.env[reference]);
    signal.throwIfAborted();
    audit.stage = 'quota';
    await requireAiModelQuota(event, actor, 1);
    signal.throwIfAborted();
    audit.stage = 'inference';
    const result = await transport.infer(selection, {responseSchema:moderationResponseSchema,messages:[
      {role:'system',content:moderationPrompt},{role:'user',content:prompt}
    ]},signal);
    if (result.finishReason !== 'stop' || result.toolCalls.length) throw new Error();
    advice = parseModelAdvice(result.text,material.rules.map(rule=>rule.id));
  } catch (error) {
    if (error instanceof AiQuotaError) throw error;
    throw new ModerationAdviceUnavailable();
  }
  signal.throwIfAborted();
  audit.stage = 'persist';
  const message = await withConnection(event,connection=>appendModerationAdvice(event,connection,id,{
    expectedSequence:request.expected_sequence,modelId:selection.profileId,configRevision:selection.configurationRevision,signal,
    ...(selection.modelVersion !== undefined ? {modelVersion:selection.modelVersion} : {}),
    review:{version:1,target:material.target,locale:request.locale,terms_digest:material.authority.digest,
      terms_generation:material.authority.generation,skill_generation:generation,advice}
  }));
  return {status:'generated',message} as const;
}
