import type {H3Event} from 'h3';
import type oracledb from 'oracledb';
import {v2Auth,v2Connection,v2ServerError} from '~/server/utils/v2';
import {appendKnowledgeAssistantMessage,listRecentConversationMessages,readConversation} from './conversation-store';
import {generateKnowledgeReply} from './knowledge-service';

export class KnowledgeConversationError extends Error {
  constructor(readonly code:'INVALID_CONTEXT'|'CANCELLED') {super(code);this.name='KnowledgeConversationError';}
}
async function withConnection<T>(event:H3Event,action:(connection:oracledb.Connection)=>Promise<T>):Promise<T> {
  let connection:oracledb.Connection;
  try {connection=await v2Connection(event);} catch {v2ServerError();}
  try {return await action(connection);} finally {try {await connection.close();} catch {v2ServerError();}}
}
const checkCancelled=(signal?:AbortSignal)=>{if(signal?.aborted) throw new KnowledgeConversationError('CANCELLED');};
/** Internal path; authorization occurs in each store operation and no DB connection is held for inference. */
export async function generateKnowledgeConversation(event:H3Event,id:string,configuration=process.env.AI_MODEL_CONFIG_JSON,signal?:AbortSignal,searchPhrase?:string) {
  v2Auth(event);checkCancelled(signal);
  const context=await withConnection(event,async connection=>({
    conversation:await readConversation(event,connection,id),
    messages:await listRecentConversationMessages(event,connection,id)
  }));
  if(context.conversation.purpose!=='knowledge' || !Array.isArray(context.messages) || !context.messages.length || context.messages.length>50) throw new KnowledgeConversationError('INVALID_CONTEXT');
  let previous=0;
  for(const message of context.messages) {
    if(!Number.isSafeInteger(message.sequence_no) || message.sequence_no<=previous || !['user','assistant'].includes(message.role) || typeof message.content!=='string' || !message.content) throw new KnowledgeConversationError('INVALID_CONTEXT');
    previous=message.sequence_no;
  }
  const last=context.messages.at(-1);
  if(!last || last.role!=='user') throw new KnowledgeConversationError('INVALID_CONTEXT');
  checkCancelled(signal);
  const result=await generateKnowledgeReply(event,last.content,configuration,signal,searchPhrase,context.messages);
  checkCancelled(signal);
  const answer=result.answer;
  if(answer===null) return {message:null};
  return withConnection(event,connection=>appendKnowledgeAssistantMessage(event,connection,id,{
    answer,sources:result.sources,...(result.contextSources?.length ? {contextSources:result.contextSources}:{}),...(result.contextSnapshot ? {contextSnapshot:result.contextSnapshot}:{}),expectedSequence:last.sequence_no,modelId:result.modelId,configRevision:result.configRevision
  }));
}
