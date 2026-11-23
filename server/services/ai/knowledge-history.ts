import type { IndexedSource, KnowledgeSource } from './knowledge-source';
import { isKnowledgeKind, parseKnowledgeAnswer, validCitationLocation, type RestoredCitation } from './knowledge-citations';
export type { RestoredCitation } from './knowledge-citations';

export class KnowledgeHistoryError extends Error {
  constructor(readonly code:'INVALID_HISTORY'|'SOURCE_CHANGED') {super(code);this.name='KnowledgeHistoryError';}
}
type KnowledgeMessage={answer:string;sources:IndexedSource[];dependencies?:IndexedSource[]};
const key=(source:IndexedSource)=>`${source.kind}:${source.id}:${source.version}`;
function references(value:unknown):IndexedSource[] {
  if(!Array.isArray(value) || value.length<1 || value.length>20) throw new KnowledgeHistoryError('INVALID_HISTORY');
  const sources:IndexedSource[]=[];const seen=new Set<string>();
  for(const raw of value) {
    if(!raw || typeof raw!=='object' || Array.isArray(raw)) throw new KnowledgeHistoryError('INVALID_HISTORY');
    const s=raw as Record<string,unknown>;
    if(Object.keys(s).length!==3 || !isKnowledgeKind(s.kind) || typeof s.id!=='number' || !Number.isSafeInteger(s.id) || s.id<1 || s.id>999999999999999 || (s.kind==='terms' && s.id>8) || typeof s.version!=='string' || !/^[0-9a-f]{64}$/.test(s.version)) throw new KnowledgeHistoryError('INVALID_HISTORY');
    const source:IndexedSource={kind:s.kind,id:s.id,version:s.version};
    if(seen.has(`${s.kind}:${s.id}`)) throw new KnowledgeHistoryError('INVALID_HISTORY');
    seen.add(`${s.kind}:${s.id}`);sources.push(source);
  }
  return sources;
}
function validate(value:unknown):KnowledgeMessage {
  if(!value || typeof value!=='object' || Array.isArray(value)) throw new KnowledgeHistoryError('INVALID_HISTORY');
  const body=value as Record<string,unknown>;
  if((body.version!==1 && body.version!==2) || Object.keys(body).length!==(body.version===1 ? 3 : 4) || typeof body.answer!=='string') throw new KnowledgeHistoryError('INVALID_HISTORY');
  const sources=references(body.sources);
  const dependencies=body.version===2 ? references(body.dependencies) : undefined;
  const allowed=dependencies ? new Set(dependencies.map(key)) : undefined;
  if(allowed && sources.some(source=>!allowed.has(key(source)))) throw new KnowledgeHistoryError('INVALID_HISTORY');
  try {
    const answer=parseKnowledgeAnswer(JSON.stringify({answer:body.answer,citations:sources}),sources);
    return {...answer,...(dependencies ? {dependencies} : {})};
  }
  catch {throw new KnowledgeHistoryError('INVALID_HISTORY');}
}
/** Stored content contains only the answer and versioned identifiers, never source text. */
export function encodeKnowledgeMessage(message:KnowledgeMessage):string {
  const version=message.dependencies ? 2 : 1;
  const checked=validate({version,...message});
  const encoded=JSON.stringify({version,...checked});
  if(Buffer.byteLength(encoded,'utf8')>65536) throw new KnowledgeHistoryError('INVALID_HISTORY');
  return encoded;
}
/** The caller must authenticate and supply a current, uncached source revalidation function. */
export async function restoreKnowledgeMessage(encoded:string,hydrate:(sources:IndexedSource[])=>Promise<KnowledgeSource[]>):Promise<KnowledgeMessage & {citations:RestoredCitation[];dependencyCitations?:RestoredCitation[]}> {
  if(typeof encoded!=='string' || Buffer.byteLength(encoded,'utf8')>65536) throw new KnowledgeHistoryError('INVALID_HISTORY');
  let raw:unknown;try {raw=JSON.parse(encoded);} catch {throw new KnowledgeHistoryError('INVALID_HISTORY');}
  const message=validate(raw);
  const required=message.dependencies ?? message.sources;
  const rows=await hydrate(required.map(s=>({...s})));
  if(!Array.isArray(rows) || rows.length!==required.length) throw new KnowledgeHistoryError('SOURCE_CHANGED');
  const expected=new Set(required.map(key));const actual=new Map<string,RestoredCitation>();
  for(const row of rows) {
    const id=key(row);
    if(!expected.has(id) || actual.has(id)) throw new KnowledgeHistoryError('SOURCE_CHANGED');
    if(!validCitationLocation(row)) throw new KnowledgeHistoryError('SOURCE_CHANGED');
    actual.set(id,{
      kind:row.kind,id:row.id,version:row.version,
      ...(row.post_id === undefined ? {} : {post_id:row.post_id}),
      ...(row.group_id === undefined ? {} : {group_id:row.group_id}),
    });
  }
  return {...message,citations:message.sources.map(source=>actual.get(key(source))!),
    ...(message.dependencies ? {dependencyCitations:required.map(source=>actual.get(key(source))!)} : {})};
}
