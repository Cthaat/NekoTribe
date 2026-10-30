import type { IndexedSource } from './knowledge-source';

export type HistoryMessage = {sequence_no:number;role:string;content:string;citations?:Array<IndexedSource & {post_id?:number}>};
type ModelHistory = {role:'user'|'assistant';content:string};
export class KnowledgeContextError extends Error {
  constructor(readonly code:'INVALID_CONTEXT'|'CONTEXT_TOO_LARGE') {super(code);this.name='KnowledgeContextError';}
}

/** Pure selection only: the caller must revalidate selected citations before delivery and commit. */
export function selectKnowledgeContext(messages:HistoryMessage[],maxBytes:number,maxSources=20):{question:string;history:ModelHistory[];sources:IndexedSource[]} {
  if (!Array.isArray(messages) || !messages.length || messages.length>50 || !Number.isSafeInteger(maxBytes) || maxBytes<0 || !Number.isInteger(maxSources) || maxSources<0 || maxSources>20) throw new KnowledgeContextError('INVALID_CONTEXT');
  let previous=0;
  for (const message of messages) {
    if (!Number.isSafeInteger(message.sequence_no) || message.sequence_no<=previous || message.sequence_no>9999999999 ||
        (message.role!=='user' && message.role!=='assistant') || typeof message.content!=='string' || !message.content || !message.content.isWellFormed()) throw new KnowledgeContextError('INVALID_CONTEXT');
    previous=message.sequence_no;
    if (message.role==='assistant') {
      if (!Array.isArray(message.citations) || !message.citations.length || message.citations.length>20) throw new KnowledgeContextError('INVALID_CONTEXT');
      const seen=new Set<string>();
      for (const source of message.citations) {
        if (!source || (source.kind!=='post' && source.kind!=='comment' && source.kind!=='terms') || !Number.isSafeInteger(source.id) || source.id<1 || source.id>999999999999999 || (source.kind==='terms' ? source.id>8 || 'post_id' in source : typeof source.post_id!=='number' || !Number.isSafeInteger(source.post_id) || source.post_id<1 || source.post_id>999999999999999 || (source.kind==='post' && source.id!==source.post_id)) || typeof source.version!=='string' || !/^[0-9a-f]{64}$/.test(source.version)) throw new KnowledgeContextError('INVALID_CONTEXT');
        const key=`${source.kind}:${source.id}`;
        if(seen.has(key)) throw new KnowledgeContextError('INVALID_CONTEXT');
        seen.add(key);
      }
    } else if (message.citations !== undefined) throw new KnowledgeContextError('INVALID_CONTEXT');
  }
  const last=messages[messages.length-1]!;
  if(last.role!=='user') throw new KnowledgeContextError('INVALID_CONTEXT');
  const question=last.content;
  const history:ModelHistory[]=[];
  const sources=new Map<string,IndexedSource>();
  const size=(items:ModelHistory[])=>Buffer.byteLength(JSON.stringify({question,history:items}),'utf8');
  if(size(history)>maxBytes) throw new KnowledgeContextError('CONTEXT_TOO_LARGE');
  for(let i=messages.length-2;i>=0;i--) {
    const message=messages[i]!;
    const next:ModelHistory[]=[{role:message.role as 'user'|'assistant',content:message.content},...history];
    if(size(next)>maxBytes) break;
    const refs=new Map(sources);
    for(const source of message.citations ?? []) {
      const key=`${source.kind}:${source.id}`,existing=refs.get(key);
      if(existing && existing.version!==source.version) throw new KnowledgeContextError('INVALID_CONTEXT');
      refs.set(key,{kind:source.kind,id:source.id,version:source.version});
    }
    if(refs.size>maxSources) break;
    history.unshift(next[0]!);
    sources.clear();for(const [key,value] of refs) sources.set(key,value);
  }
  return {question,history,sources:[...sources.values()]};
}
