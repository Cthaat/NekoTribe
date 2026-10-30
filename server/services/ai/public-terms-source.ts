import {createHash} from 'node:crypto';

type Locale='zh'|'en';
export interface TermsReference {kind:'terms';id:number;version:string}
export interface TermsSource extends TermsReference {key:string;locale:Locale;href:string;title:string;blocks:string[]}
export type TermsCatalog=readonly TermsSource[];
export class TermsSourceError extends Error {
  constructor(readonly code:'INVALID_CATALOG'|'INVALID_QUERY'|'INVALID_REFERENCE') {super(code);this.name='TermsSourceError';}
}
const sections=['acceptance','accounts','conduct','termination'] as const;
const validText=(value:unknown):value is string=>typeof value==='string' && value.isWellFormed() && !!value.trim() && Buffer.byteLength(value,'utf8')<=65536;
const object=(value:unknown):value is Record<string,unknown>=>!!value && typeof value==='object' && !Array.isArray(value);
const clone=(source:TermsSource):TermsSource=>({...source,blocks:[...source.blocks]});

/** Domain-separated UTF-8 length framing avoids ambiguity across arbitrary text blocks. */
function version(id:number,key:string,locale:Locale,href:string,title:string,blocks:string[]):string {
  const hash=createHash('sha256').update('neko-ai-terms-v1\0','utf8');
  for(const value of [String(id),key,locale,href,title,String(blocks.length),...blocks]) hash.update(`${Buffer.byteLength(value,'utf8')}:`,'utf8').update(value,'utf8');
  return hash.digest('hex');
}

/** Compile the exact reviewed catalog; callers must separately authenticate and enforce deployment consistency. */
export function parseTermsCatalog(input:unknown):TermsCatalog {
  if(!object(input) || input.id!=='AI-PUBLIC-TERMS-CATALOG' || input.revision!==1 || input.source!=='i18n/locales/{locale}.json#auth.terms.sections' || !Array.isArray(input.documents) || input.documents.length!==8) throw new TermsSourceError('INVALID_CATALOG');
  const rows:TermsSource[]=[];
  for(const [localeIndex,locale] of (['zh','en'] as const).entries()) {
    for(const [index,section] of sections.entries()) {
      const key=`terms.${section}`,href=`/${locale}/auth/terms#${section}`;
      const matches=input.documents.filter(value=>object(value) && value.key===key && value.locale===locale);
      if(matches.length!==1) throw new TermsSourceError('INVALID_CATALOG');
      const item=matches[0];
      if(!object(item) || item.href!==href || !validText(item.title) || !Array.isArray(item.blocks) || item.blocks.length!==(section==='conduct'?5:1) || !item.blocks.every(validText)) throw new TermsSourceError('INVALID_CATALOG');
      const id=localeIndex*4+index+1,blocks=[...item.blocks] as string[];
      rows.push({kind:'terms',id,key,locale,href,title:item.title,blocks,version:version(id,key,locale,href,item.title,blocks)});
    }
  }
  return rows;
}

/** Exact case-sensitive substring matching, using the same input limits as post discovery. */
export function discoverPublicTerms(catalog:TermsCatalog,query:unknown,limit:unknown):TermsSource[] {
  if(typeof query!=='string' || !query.isWellFormed() || typeof limit!=='number' || !Number.isInteger(limit) || limit<1 || limit>20) throw new TermsSourceError('INVALID_QUERY');
  const term=query.trim();
  if(!term || /[\u0000-\u001f\u007f]/.test(term) || Buffer.byteLength(term,'utf8')>256) throw new TermsSourceError('INVALID_QUERY');
  return catalog.filter(row=>row.title.includes(term) || row.blocks.some(block=>block.includes(term))).slice(0,limit).map(clone);
}

/** Omit valid but stale or unknown references; malformed and duplicate references fail closed. */
export function hydratePublicTerms(catalog:TermsCatalog,input:unknown):TermsSource[] {
  if(!Array.isArray(input) || input.length>20) throw new TermsSourceError('INVALID_REFERENCE');
  const seen=new Set<number>(),output:TermsSource[]=[];
  for(const item of input) {
    if(!object(item) || Object.keys(item).length!==3 || item.kind!=='terms' || typeof item.id!=='number' || !Number.isSafeInteger(item.id) || item.id<1 || item.id>999999999999999 || typeof item.version!=='string' || !/^[0-9a-f]{64}$/.test(item.version) || seen.has(item.id)) throw new TermsSourceError('INVALID_REFERENCE');
    seen.add(item.id);
    const found=catalog.find(row=>row.id===item.id && row.version===item.version);
    if(found) output.push(clone(found));
  }
  return output;
}
