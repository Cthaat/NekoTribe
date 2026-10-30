import type { AiModelRouter, AiModelSelection } from './model-configuration.ts';
import type { AiInferenceResult } from './inference-transport.ts';

type Message = { sequence_no:number; role:string; content:string };
type TurnMessage = { role:'system'|'user'|'assistant'; content:string };
type WriteInput = { content:string; expectedSequence:number; modelId:string; configRevision:number };
export interface WritingDependencies<T> {
  router: Pick<AiModelRouter,'select'>;
  load: () => Promise<{purpose:string;messages:Message[]}>;
  infer: (selection:AiModelSelection, input:{messages:TurnMessage[]}, signal?:AbortSignal) => Promise<Pick<AiInferenceResult,'text'|'toolCalls'|'finishReason'>>;
  write: (input:WriteInput) => Promise<T>;
}
export class WritingTurnError extends Error {
  readonly code:'INVALID_CONTEXT'|'CONTEXT_TOO_LARGE'|'PROVIDER_FAILED'|'CANCELLED';
  constructor(code:'INVALID_CONTEXT'|'CONTEXT_TOO_LARGE'|'PROVIDER_FAILED'|'CANCELLED') { super(code); this.code=code; this.name='WritingTurnError'; }
}
const system='你是写作助手。根据用户提供的内容提供可审阅的草稿和修改建议；不要假装已发布或执行任何操作。';
/** Caller supplies server-authorized store functions; never holds a DB transaction across inference. */
export async function runWritingTurn<T>(deps:WritingDependencies<T>, signal?:AbortSignal):Promise<T> {
  if(signal?.aborted) throw new WritingTurnError('CANCELLED');
  const selection=deps.router.select('writing');
  if(selection.configurationRevision>999999999999999) throw new WritingTurnError('INVALID_CONTEXT');
  const loaded=await deps.load();
  if(loaded.purpose!=='writing' || !Array.isArray(loaded.messages) || loaded.messages.length===0 || loaded.messages.length>50) throw new WritingTurnError('INVALID_CONTEXT');
  let previous=0;
  for(const message of loaded.messages) {
    if(!Number.isSafeInteger(message.sequence_no) || message.sequence_no<=previous ||
       !['user','assistant'].includes(message.role) || typeof message.content!=='string' || !message.content) throw new WritingTurnError('INVALID_CONTEXT');
    previous=message.sequence_no;
  }
  const last=loaded.messages[loaded.messages.length-1];
  if(!last || last.role!=='user') throw new WritingTurnError('INVALID_CONTEXT');
  // Upper bound based on UTF-8 bytes plus reserved template/role overhead, not a tokenizer claim.
  let budget=Math.min(16384,selection.contextWindowTokens-selection.maxOutputTokens-512)-Buffer.byteLength(system,'utf8');
  const selected:TurnMessage[]=[];
  for(let i=loaded.messages.length-1;i>=0;i--) {
    const message=loaded.messages[i]!;
    const cost=Buffer.byteLength(message.content,'utf8')+16;
    if(cost>budget) break;
    budget-=cost;
    selected.unshift({role:message.role as 'user'|'assistant',content:message.content});
  }
  if(!selected.length) throw new WritingTurnError('CONTEXT_TOO_LARGE');
  if(signal?.aborted) throw new WritingTurnError('CANCELLED');
  let answer:Pick<AiInferenceResult,'text'|'toolCalls'|'finishReason'>;
  try {answer=await deps.infer(selection,{messages:[{role:'system',content:system},...selected]},signal);}
  catch {throw new WritingTurnError(signal?.aborted?'CANCELLED':'PROVIDER_FAILED');}
  if(signal?.aborted) throw new WritingTurnError('CANCELLED');
  if(answer.finishReason!=='stop' || answer.toolCalls.length!==0 || !answer.text || Buffer.byteLength(answer.text,'utf8')>65536) throw new WritingTurnError('PROVIDER_FAILED');
  return deps.write({content:answer.text,expectedSequence:last.sequence_no,modelId:selection.profileId,configRevision:selection.configurationRevision});
}
