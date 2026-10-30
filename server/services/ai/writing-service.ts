import type { H3Event } from 'h3';
import type oracledb from 'oracledb';
import { v2Auth, v2Connection, v2ServerError } from '~/server/utils/v2';
import { appendAssistantMessage, listRecentConversationMessages, readConversation } from './conversation-store';
import { AiModelRouter } from './model-configuration.ts';
import { AiInferenceTransport } from './inference-transport.ts';
import { runWritingTurn, WritingTurnError } from './writing-turn.ts';

async function withConnection<T>(event:H3Event, action:(connection:oracledb.Connection)=>Promise<T>):Promise<T> {
  let connection:oracledb.Connection;
  try {connection=await v2Connection(event);} catch {v2ServerError();}
  try {return await action(connection);}
  finally {try {await connection.close();} catch {v2ServerError();}}
}
/** Configuration and credentials are supplied by the server environment, never the client. */
export async function generateWritingReply(event:H3Event,id:string,configuration=process.env.AI_MODEL_CONFIG_JSON,signal?:AbortSignal) {
  v2Auth(event);
  let router:AiModelRouter;
  try {
    if(!configuration || Buffer.byteLength(configuration,'utf8')>65536) throw new Error();
    router=new AiModelRouter(JSON.parse(configuration));
  } catch {throw new WritingTurnError('PROVIDER_FAILED');}
  const transport=new AiInferenceTransport(reference=>process.env[reference]);
  return runWritingTurn({
    router,
    load:()=>withConnection(event,async connection=>({
      purpose:(await readConversation(event,connection,id)).purpose,
      messages:await listRecentConversationMessages(event,connection,id)
    })),
    infer:(selection,input,cancel)=>transport.infer(selection,input,cancel),
    write:input=>withConnection(event,connection=>appendAssistantMessage(event,connection,id,input))
  },signal);
}
