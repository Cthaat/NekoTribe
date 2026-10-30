import type { IndexedSource, KnowledgeSource } from './knowledge-source';

export class KnowledgeTurnError extends Error {
  constructor(readonly code:'CANCELLED'|'INVALID_SOURCE'|'SOURCE_CHANGED'|'INVALID_ANSWER') { super(code); this.name='KnowledgeTurnError'; }
}
export interface KnowledgeTurnDependencies {
  discover:()=>Promise<KnowledgeSource[]>;
  hydrate:(candidates:IndexedSource[])=>Promise<KnowledgeSource[]>;
  infer:(sources:KnowledgeSource[],signal?:AbortSignal)=>Promise<string>;
}
const candidate=(source:KnowledgeSource):IndexedSource=>({kind:source.kind,id:source.id,version:source.version});
const key=(source:IndexedSource)=>`${source.kind}:${source.id}`;
function checkCancelled(signal?:AbortSignal):void { if(signal?.aborted) throw new KnowledgeTurnError('CANCELLED'); }
function checkedRows(candidates:IndexedSource[],rows:KnowledgeSource[]):KnowledgeSource[] {
  if (!Array.isArray(rows) || rows.length>candidates.length) throw new KnowledgeTurnError('INVALID_SOURCE');
  const expected=new Map(candidates.map(value=>[key(value),value.version]));
  const seen=new Set<string>();
  for(const row of rows) {
    const id=key(row);
    if(seen.has(id) || !expected.has(id) || expected.get(id)!==row.version) throw new KnowledgeTurnError('INVALID_SOURCE');
    seen.add(id);
  }
  return rows;
}
/** Isolated orchestration boundary; it does not persist answers or expose an HTTP route. */
export async function runKnowledgeTurn(deps:KnowledgeTurnDependencies,signal?:AbortSignal):Promise<{answer:string|null;sources:IndexedSource[]}> {
  checkCancelled(signal);
  const discovered=await deps.discover();
  checkCancelled(signal);
  if(!Array.isArray(discovered) || discovered.length>20) throw new KnowledgeTurnError('INVALID_SOURCE');
  const candidates=discovered.map(candidate);
  if(new Set(candidates.map(key)).size!==candidates.length) throw new KnowledgeTurnError('INVALID_SOURCE');
  const sources=checkedRows(candidates,await deps.hydrate(candidates)).map(row=>({...row}));
  checkCancelled(signal);
  if(!sources.length) return {answer:null,sources:[]};
  const used=sources.map(candidate);
  const answer=await deps.infer(sources.map(row=>({...row})),signal);
  checkCancelled(signal);
  if(typeof answer!=='string' || !answer || !answer.isWellFormed() || Buffer.byteLength(answer,'utf8')>65536) throw new KnowledgeTurnError('INVALID_ANSWER');
  const after=checkedRows(used,await deps.hydrate(used));
  checkCancelled(signal);
  const current=new Map(after.map(row=>[key(row),row]));
  if(after.length!==sources.length || sources.some(row=>{const item=current.get(key(row));return !item || item.post_id!==row.post_id || item.content!==row.content;})) throw new KnowledgeTurnError('SOURCE_CHANGED');
  return {answer,sources:used};
}
