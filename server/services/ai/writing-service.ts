import type { H3Event } from 'h3';
import type oracledb from 'oracledb';
import { v2Auth, v2Connection, v2ServerError } from '~/server/utils/v2';
import { requireAiModelQuota } from '~/server/utils/ai-model-quota';
import { appendAssistantMessage, listRecentConversationMessages, readConversation } from './conversation-store';
import type { AiModelRouter } from './model-configuration.ts';
import { configuredModelRouter } from './model-source.ts';
import { AiInferenceTransport } from './inference-transport.ts';
import { runWritingTurn, WritingTurnError } from './writing-turn.ts';
import { selectConfiguredConversationSkill } from './skill-conversation';
import { AiRunAudit } from './run-audit';
import { generationDeltas } from './stream-response';
import { personalWritingKeyReference, personalWritingProvider } from './user-provider';

async function withConnection<T>(event:H3Event, action:(connection:oracledb.Connection)=>Promise<T>):Promise<T> {
  let connection:oracledb.Connection;
  try {connection=await v2Connection(event);} catch {v2ServerError();}
  try {return await action(connection);}
  finally {try {await connection.close();} catch {v2ServerError();}}
}
/** Resolve the provider through the authenticated writer's saved account settings. */
export async function generateWritingReply(event:H3Event,id:string,configuration?:string,signal?:AbortSignal,skillId: 'writing-draft' | null = null,expectedSequence?:number) {
  const actor=v2Auth(event);
  let router:Pick<AiModelRouter,'select'>;
  let credential:string|undefined;
  try {
    const personal = await personalWritingProvider(event,actor.userId);
    if (personal?.kind === 'unusable') throw new WritingTurnError('PROVIDER_FAILED');
    if (personal?.kind === 'personal') {
      router = {select:()=>personal.selection};
      credential = personal.credential;
    } else router=await configuredModelRouter(configuration);
  } catch {throw new WritingTurnError('PROVIDER_FAILED');}
  const transport=new AiInferenceTransport(reference=>
    credential !== undefined && reference === personalWritingKeyReference ? credential : process.env[reference]);
  let skillGeneration:number|undefined;
  let configRevision=0;
  const audit: { current?: AiRunAudit } = {};
  const turn=runWritingTurn({
    router:{select:(...args)=>{
      const selection=router.select(...args);
      configRevision=selection.configurationRevision;
      return selection;
    }},
    load:()=>withConnection(event,async connection=>{
      const conversation=await readConversation(event,connection,id);
      const messages=await listRecentConversationMessages(event,connection,id);
      if(conversation.purpose==='writing') {
        const selected=await selectConfiguredConversationSkill(event,connection,{ownerUserId:actor.userId,purpose:conversation.purpose,groupId:conversation.group_id},skillId);
        skillGeneration=selected.configGeneration;
        audit.current=new AiRunAudit(event,'writing_draft',skillGeneration,skillId ? 'explicit' : 'purpose-default');
        audit.current.configRevision=configRevision;
      }
      return {purpose:conversation.purpose,messages};
    }),
    reserve:()=>{
      if(audit.current) audit.current.stage='quota';
      return requireAiModelQuota(event,actor.userId,1);
    },
    infer:(selection,input,cancel)=>{
      if(audit.current) audit.current.stage='inference';
      return transport.infer(selection,input,cancel,generationDeltas(event));
    },
    write:async input=>{
      if(audit.current) audit.current.stage='persist';
      try {
        return await withConnection(event,connection=>{
          if(skillGeneration===undefined) throw new WritingTurnError('PROVIDER_FAILED');
          return appendAssistantMessage(event,connection,id,{...input,skillGeneration,signal});
        });
      } catch (error) {
        if(signal?.aborted && error===signal.reason) throw new WritingTurnError('CANCELLED');
        throw error;
      }
    }
  },signal,expectedSequence);
  try {
    const saved=await turn;
    audit.current?.finish('generated');
    return saved;
  } catch(error) {
    audit.current?.fail(error,signal);
    throw error;
  }
}
