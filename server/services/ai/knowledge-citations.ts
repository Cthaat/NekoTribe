import type { IndexedSource } from './knowledge-source';

export const isGroupKnowledgeKind = (kind: unknown): kind is 'group_post' | 'group_comment' =>
  kind === 'group_post' || kind === 'group_comment';
export const isKnowledgeKind = (kind: unknown): kind is IndexedSource['kind'] =>
  kind === 'post' || kind === 'comment' || kind === 'terms' || isGroupKnowledgeKind(kind);

export type RestoredCitation = IndexedSource & {post_id?:number;group_id?:number};
const validId = (id: unknown): id is number =>
  typeof id === 'number' && Number.isSafeInteger(id) && id >= 1 && id <= 999_999_999_999_999;

export function validCitationLocation(source: RestoredCitation): boolean {
  if (source.kind === 'terms') return source.id <= 8 && !('post_id' in source) && !('group_id' in source);
  if (!validId(source.post_id) || ((source.kind === 'post' || source.kind === 'group_post') && source.id !== source.post_id)) return false;
  return isGroupKnowledgeKind(source.kind)
    ? typeof source.group_id === 'number' && Number.isSafeInteger(source.group_id) && source.group_id >= 1
    : !('group_id' in source);
}
export class KnowledgeCitationError extends Error {
  constructor() {super('INVALID_CITATIONS');this.name='KnowledgeCitationError';}
}
const invalid=():never=>{throw new KnowledgeCitationError();};
const key=(source:IndexedSource)=>`${source.kind}:${source.id}:${source.version}`;
/** Validate references against the exact sources already checked for this turn. */
export function parseKnowledgeAnswer(text:string,verified:IndexedSource[],numbered=false):{answer:string;sources:IndexedSource[]} {
  let value:unknown;
  try {value=JSON.parse(text);} catch {return invalid();}
  if(!value || typeof value!=='object' || Array.isArray(value)) return invalid();
  const object=value as Record<string,unknown>;
  if(Object.keys(object).length!==2 || typeof object.answer!=='string' || !object.answer.trim() || !object.answer.isWellFormed() || Buffer.byteLength(object.answer,'utf8')>65536 || !Array.isArray(object.citations) || object.citations.length<1 || object.citations.length>20) return invalid();
  const permitted=new Map(verified.map(source=>[key(source),source]));
  const seen=new Set<string>();const sources:IndexedSource[]=[];
  for(const raw of object.citations) {
    let matched:IndexedSource|undefined;
    if (numbered) {
      if (typeof raw!=='number' || !Number.isInteger(raw) || raw<1 || raw>verified.length) return invalid();
      matched=verified[raw-1];
    } else {
      if(!raw || typeof raw!=='object' || Array.isArray(raw)) return invalid();
      const citation=raw as Record<string,unknown>;
      if(Object.keys(citation).length!==3 || !isKnowledgeKind(citation.kind) || !validId(citation.id) || (citation.kind==='terms' && citation.id>8) || typeof citation.version!=='string') return invalid();
      matched=permitted.get(key({kind:citation.kind,id:citation.id,version:citation.version}));
    }
    if(!matched || seen.has(key(matched))) return invalid();
    seen.add(key(matched));sources.push({...matched});
  }
  return {answer:object.answer,sources};
}
