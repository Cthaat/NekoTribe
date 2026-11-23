import type {H3Event} from 'h3';
import type oracledb from 'oracledb';
import {v2Auth,v2Connection,v2ServerError} from '~/server/utils/v2';
import {appendKnowledgeAssistantMessage,knowledgeFilter,listRecentConversationMessages,readConversation} from './conversation-store';
import {generateKnowledgeReply} from './knowledge-service';
import {selectConfiguredConversationSkill} from './skill-conversation';
import {AiRunAudit} from './run-audit';

export class KnowledgeConversationError extends Error {
  constructor(readonly code:'INVALID_CONTEXT'|'CANCELLED'|'SEQUENCE_CONFLICT') {super(code);this.name='KnowledgeConversationError';}
}
async function withConnection<T>(event:H3Event,action:(connection:oracledb.Connection)=>Promise<T>):Promise<T> {
  let connection:oracledb.Connection;
  try {connection=await v2Connection(event);} catch {v2ServerError();}
  try {return await action(connection);} finally {try {await connection.close();} catch {v2ServerError();}}
}
const checkCancelled=(signal?:AbortSignal)=>{if(signal?.aborted) throw new KnowledgeConversationError('CANCELLED');};
/** Internal path; authorization occurs in each store operation and no DB connection is held for inference. */
export async function generateKnowledgeConversation(event:H3Event,id:string,configuration?:string,signal?:AbortSignal,searchPhrase?:string,skillId:'knowledge-answer'|null=null,expectedSequence?:number) {
  const actor=v2Auth(event);checkCancelled(signal);
  const context=await withConnection(event,async connection=>{
    const conversation=await readConversation(event,connection,id);
    const messages=await listRecentConversationMessages(event,connection,id);
    if(conversation.purpose!=='knowledge') throw new KnowledgeConversationError('INVALID_CONTEXT');
    const selected=await selectConfiguredConversationSkill(event,connection,{ownerUserId:actor.userId,purpose:conversation.purpose,groupId:conversation.group_id,knowledgeScope:conversation.knowledge_scope},skillId);
    return {conversation,messages,skillGeneration:selected.configGeneration};
  });
  if(context.conversation.purpose!=='knowledge' || !Array.isArray(context.messages) || context.messages.length>50) throw new KnowledgeConversationError('INVALID_CONTEXT');
  let previous=0;
  for(const message of context.messages) {
    if(!Number.isSafeInteger(message.sequence_no) || message.sequence_no<=previous || !['user','assistant'].includes(message.role) || typeof message.content!=='string' || !message.content) throw new KnowledgeConversationError('INVALID_CONTEXT');
    previous=message.sequence_no;
  }
  const last=context.messages.at(-1);
  if(expectedSequence !== undefined && (last?.sequence_no !== expectedSequence || last.role !== 'user')) throw new KnowledgeConversationError('SEQUENCE_CONFLICT');
  if(!last || last.role!=='user') throw new KnowledgeConversationError('INVALID_CONTEXT');
  const audit=new AiRunAudit(event,'knowledge_answer',context.skillGeneration,skillId ? 'explicit' : 'purpose-default');
  try {
    checkCancelled(signal);
    const result=await generateKnowledgeReply(event,last.content,configuration,signal,searchPhrase,context.messages,audit,knowledgeFilter(context.conversation));
    checkCancelled(signal);
    const answer=result.answer;
    if(answer===null) {
      audit.finish('insufficient_evidence');
      return {message:null};
    }
    audit.stage='persist';
    const saved=await withConnection(event,connection=>appendKnowledgeAssistantMessage(event,connection,id,{
      answer,sources:result.sources,...(result.dependencies ? {dependencies:result.dependencies} : {}),...(result.contextSources?.length ? {contextSources:result.contextSources}:{}),...(result.contextSnapshot ? {contextSnapshot:result.contextSnapshot}:{}),expectedSequence:last.sequence_no,modelId:result.modelId,configRevision:result.configRevision,skillGeneration:context.skillGeneration,
      ...(result.modelVersion !== undefined ? {modelVersion:result.modelVersion} : {}),
      signal
    }));
    audit.finish('generated');
    return saved;
  } catch (error) {
    audit.fail(error,signal);
    if(signal?.aborted && error===signal.reason) throw new KnowledgeConversationError('CANCELLED');
    throw error;
  }
}
