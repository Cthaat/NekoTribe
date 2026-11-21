import type { IndexedSource, KnowledgeSource } from './knowledge-source';

export class KnowledgeTurnError extends Error {
  constructor(readonly code:'CANCELLED'|'INVALID_SOURCE'|'SOURCE_CHANGED'|'INVALID_ANSWER') { super(code); this.name='KnowledgeTurnError'; }
}
export type KnowledgeHit = IndexedSource & {chunk?: number};
export interface KnowledgeTurnDependencies {
  discover:()=>Promise<KnowledgeHit[]>;
  refreshStale?:(hits:KnowledgeHit[])=>Promise<KnowledgeHit[] | null>;
  hydrate:(candidates:IndexedSource[])=>Promise<KnowledgeSource[]>;
  selectEvidence?:(sources:KnowledgeSource[], hits:KnowledgeHit[])=>KnowledgeSource[];
  infer:(sources:KnowledgeSource[],signal?:AbortSignal)=>Promise<string>;
}
const candidate=(source:IndexedSource):IndexedSource=>({kind:source.kind,id:source.id,version:source.version});
const key=(source:IndexedSource)=>`${source.kind}:${source.id}`;
export function indexedChunk(content:string,chunk:number):string[]|null {
  if(!Number.isInteger(chunk) || chunk<0 || chunk>102) return null;
  const start=chunk*640;
  const characters=Array.from(content).slice(start,start+768);
  return characters.join('').trim() ? characters : null;
}
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
  const hydrateHits=async(hits:KnowledgeHit[])=>{
    checkCancelled(signal);
    if(!Array.isArray(hits) || hits.length>20) throw new KnowledgeTurnError('INVALID_SOURCE');
    const candidates=hits.map(candidate);
    if(new Set(candidates.map(key)).size!==candidates.length) throw new KnowledgeTurnError('INVALID_SOURCE');
    const rows=checkedRows(candidates,await deps.hydrate(candidates)).map(row=>({...row}));
    checkCancelled(signal);
    const chunks=new Map(hits.map(hit=>[key(hit),hit.chunk]));
    return rows.filter(row=>{
      const chunk=chunks.get(key(row));
      return chunk===undefined || indexedChunk(row.content,chunk)!==null;
    });
  };
  checkCancelled(signal);
  let discovered=await deps.discover();
  let hydrated=await hydrateHits(discovered);
  if(discovered.length && !hydrated.length && deps.refreshStale) {
    const refreshed=await deps.refreshStale(discovered);
    checkCancelled(signal);
    if(refreshed!==null) {
      discovered=refreshed;
      hydrated=await hydrateHits(discovered);
    }
  }
  if(!hydrated.length) return {answer:null,sources:[]};
  const evidence=deps.selectEvidence?.(hydrated,discovered) ?? hydrated;
  const sources=hydrated.slice(0,evidence.length);
  const used=sources.map(candidate);
  const answer=await deps.infer(evidence.map(row=>({...row})),signal);
  checkCancelled(signal);
  if(typeof answer!=='string' || !answer || !answer.isWellFormed() || Buffer.byteLength(answer,'utf8')>65536) throw new KnowledgeTurnError('INVALID_ANSWER');
  const after=checkedRows(used,await deps.hydrate(used));
  checkCancelled(signal);
  const current=new Map(after.map(row=>[key(row),row]));
  if(after.length!==sources.length || sources.some(row=>{const item=current.get(key(row));return !item || item.post_id!==row.post_id || item.group_id!==row.group_id || item.content!==row.content;})) throw new KnowledgeTurnError('SOURCE_CHANGED');
  return {answer,sources:used};
}
