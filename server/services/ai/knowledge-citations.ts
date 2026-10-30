import type { IndexedSource } from './knowledge-source';

export class KnowledgeCitationError extends Error {
  constructor() {super('INVALID_CITATIONS');this.name='KnowledgeCitationError';}
}
const invalid=():never=>{throw new KnowledgeCitationError();};
const key=(source:IndexedSource)=>`${source.kind}:${source.id}:${source.version}`;
/** Validate references against the exact sources already checked for this turn. */
export function parseKnowledgeAnswer(text:string,verified:IndexedSource[]):{answer:string;sources:IndexedSource[]} {
  let value:unknown;
  try {value=JSON.parse(text);} catch {return invalid();}
  if(!value || typeof value!=='object' || Array.isArray(value)) return invalid();
  const object=value as Record<string,unknown>;
  if(Object.keys(object).length!==2 || typeof object.answer!=='string' || !object.answer.trim() || !object.answer.isWellFormed() || Buffer.byteLength(object.answer,'utf8')>65536 || !Array.isArray(object.citations) || object.citations.length<1 || object.citations.length>20) return invalid();
  const permitted=new Map(verified.map(source=>[key(source),source]));
  const seen=new Set<string>();const sources:IndexedSource[]=[];
  for(const raw of object.citations) {
    if(!raw || typeof raw!=='object' || Array.isArray(raw)) return invalid();
    const citation=raw as Record<string,unknown>;
    if(Object.keys(citation).length!==3 || (citation.kind!=='post' && citation.kind!=='comment') || typeof citation.id!=='number' || !Number.isSafeInteger(citation.id) || citation.id<=0 || typeof citation.version!=='string') return invalid();
    const id=key({kind:citation.kind,id:citation.id,version:citation.version});
    const matched=permitted.get(id);
    if(!matched || seen.has(id)) return invalid();
    seen.add(id);sources.push({...matched});
  }
  return {answer:object.answer,sources};
}
