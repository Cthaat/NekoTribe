import type { IndexedSource, KnowledgeSource } from './knowledge-source';
import { parseKnowledgeAnswer } from './knowledge-citations';

export class KnowledgeHistoryError extends Error {
  constructor(readonly code:'INVALID_HISTORY'|'SOURCE_CHANGED') {super(code);this.name='KnowledgeHistoryError';}
}
type KnowledgeMessage={answer:string;sources:IndexedSource[]};
export type RestoredCitation = IndexedSource & {post_id?:number};
const key=(source:IndexedSource)=>`${source.kind}:${source.id}:${source.version}`;
function validate(value:unknown):KnowledgeMessage {
  if(!value || typeof value!=='object' || Array.isArray(value)) throw new KnowledgeHistoryError('INVALID_HISTORY');
  const body=value as Record<string,unknown>;
  if(Object.keys(body).length!==3 || body.version!==1 || typeof body.answer!=='string' || !Array.isArray(body.sources) || body.sources.length<1 || body.sources.length>20) throw new KnowledgeHistoryError('INVALID_HISTORY');
  const sources:IndexedSource[]=[];const seen=new Set<string>();
  for(const raw of body.sources) {
    if(!raw || typeof raw!=='object' || Array.isArray(raw)) throw new KnowledgeHistoryError('INVALID_HISTORY');
    const s=raw as Record<string,unknown>;
    if(Object.keys(s).length!==3 || (s.kind!=='post' && s.kind!=='comment' && s.kind!=='terms') || typeof s.id!=='number' || !Number.isSafeInteger(s.id) || s.id<1 || s.id>999999999999999 || (s.kind==='terms' && s.id>8) || typeof s.version!=='string' || !/^[0-9a-f]{64}$/.test(s.version)) throw new KnowledgeHistoryError('INVALID_HISTORY');
    const source:IndexedSource={kind:s.kind,id:s.id,version:s.version};
    if(seen.has(`${s.kind}:${s.id}`)) throw new KnowledgeHistoryError('INVALID_HISTORY');
    seen.add(`${s.kind}:${s.id}`);sources.push(source);
  }
  try {return parseKnowledgeAnswer(JSON.stringify({answer:body.answer,citations:sources}),sources);}
  catch {throw new KnowledgeHistoryError('INVALID_HISTORY');}
}
/** Stored content contains only the answer and versioned identifiers, never source text. */
export function encodeKnowledgeMessage(message:KnowledgeMessage):string {
  const checked=validate({version:1,answer:message.answer,sources:message.sources});
  const encoded=JSON.stringify({version:1,...checked});
  if(Buffer.byteLength(encoded,'utf8')>65536) throw new KnowledgeHistoryError('INVALID_HISTORY');
  return encoded;
}
/** The caller must authenticate and supply a current, uncached source revalidation function. */
export async function restoreKnowledgeMessage(encoded:string,hydrate:(sources:IndexedSource[])=>Promise<KnowledgeSource[]>):Promise<KnowledgeMessage & {citations:RestoredCitation[]}> {
  if(typeof encoded!=='string' || Buffer.byteLength(encoded,'utf8')>65536) throw new KnowledgeHistoryError('INVALID_HISTORY');
  let raw:unknown;try {raw=JSON.parse(encoded);} catch {throw new KnowledgeHistoryError('INVALID_HISTORY');}
  const message=validate(raw);
  const rows=await hydrate(message.sources.map(s=>({...s})));
  if(!Array.isArray(rows) || rows.length!==message.sources.length) throw new KnowledgeHistoryError('SOURCE_CHANGED');
  const expected=new Set(message.sources.map(key));const actual=new Map<string,RestoredCitation>();
  for(const row of rows) {
    const id=key(row);
    if(!expected.has(id) || actual.has(id)) throw new KnowledgeHistoryError('SOURCE_CHANGED');
    if(row.kind==='terms') {
      if(row.id>8 || 'post_id' in row) throw new KnowledgeHistoryError('SOURCE_CHANGED');
      actual.set(id,{kind:row.kind,id:row.id,version:row.version});
    } else {
      if(typeof row.post_id!=='number' || !Number.isSafeInteger(row.post_id) || row.post_id<1 || row.post_id>999999999999999 || (row.kind==='post' && row.post_id!==row.id)) throw new KnowledgeHistoryError('SOURCE_CHANGED');
      actual.set(id,{kind:row.kind,id:row.id,version:row.version,post_id:row.post_id});
    }
  }
  return {...message,citations:message.sources.map(source=>actual.get(key(source))!)};
}
