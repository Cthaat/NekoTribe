import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {test} from 'node:test';
import {build} from 'esbuild';
import {fileURLToPath} from 'node:url';

const root=fileURLToPath(new URL('../',import.meta.url));
const stubs={
  oracledb:`export default {OUT_FORMAT_OBJECT:4002};`,
  '~/server/utils/v2':`export const v2Auth=e=>{if(!e.userId)throw Error('401')};`,
  '~/server/database/readiness':`export const requireFeatureSchema=async(db,feature)=>{db.checked=feature;if(db.unready)throw Error('schema secret')};`
};
const built=await build({stdin:{contents:`export * from './server/services/ai/public-terms-authority.ts'`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'authority-stubs',setup(b){b.onResolve({filter:/.*/},a=>Object.hasOwn(stubs,a.path)?{path:a.path,namespace:'stub'}:undefined);b.onLoad({filter:/.*/,namespace:'stub'},a=>({contents:stubs[a.path],loader:'js'}))}}]});
const {termsCatalogDigest,readTermsAuthority}=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);
const raw=JSON.parse(readFileSync(new URL('../specifications/requirements/ai-public-terms-catalog.json',import.meta.url),'utf8'));
const vectors=JSON.parse(readFileSync(new URL('../specifications/scenarios/ai-public-terms-source-vectors.json',import.meta.url),'utf8'));

test('catalog digest uses the shared independent vector and invalidates changes',()=>{
 assert.equal(termsCatalogDigest(raw),vectors.catalog_digest);
 const changed=structuredClone(raw);changed.documents[0].blocks[0]+='更新';
 assert.notEqual(termsCatalogDigest(changed),vectors.catalog_digest);
 const reordered=structuredClone(raw);reordered.documents.reverse();assert.equal(termsCatalogDigest(reordered),vectors.catalog_digest);
});
test('authenticated reader checks the persistent singleton on every request',async()=>{
 let calls=0;const db={async execute(sql,binds,options){calls++;assert.match(sql,/FROM\s+n_ai_terms_active/i);assert.deepEqual(binds,{singleton_id:1});assert.equal(options.outFormat,4002);return {rows:[{CATALOG_DIGEST:vectors.catalog_digest,GENERATION:3,ENABLED:1}]}}};
 assert.deepEqual(await readTermsAuthority({userId:42},db,raw),{digest:vectors.catalog_digest,generation:3});
 assert.equal(db.checked,'ai-terms');await readTermsAuthority({userId:42},db,raw);assert.equal(calls,2);
 await assert.rejects(()=>readTermsAuthority({},db,raw),/401/);assert.equal(calls,2);
});
test('transactional check requests a row lock while ordinary reads remain unlocked',async()=>{
 const sqls=[];const db={async execute(sql){sqls.push(sql);return {rows:[{CATALOG_DIGEST:vectors.catalog_digest,GENERATION:1,ENABLED:1}]}}};
 await readTermsAuthority({userId:1},db,raw);await readTermsAuthority({userId:1},db,raw,{lock:true});
 assert.doesNotMatch(sqls[0],/FOR UPDATE/i);assert.match(sqls[1],/FOR UPDATE/i);
});
test('missing, disabled, stale, corrupt and unavailable authority fails closed',async()=>{
 const valid={CATALOG_DIGEST:vectors.catalog_digest,GENERATION:1,ENABLED:1};
 for(const rows of [[],[valid,valid],[{...valid,ENABLED:0}],[{...valid,CATALOG_DIGEST:'0'.repeat(64)}],[{...valid,GENERATION:0}],[{...valid,GENERATION:1.5}],[{...valid,GENERATION:1e15}],[{...valid,CATALOG_DIGEST:null}]]) {
  await assert.rejects(()=>readTermsAuthority({userId:1},{async execute(){return {rows}}},raw),/TERMS_AUTHORITY_UNAVAILABLE/);
 }
 for(const db of [{unready:true},{async execute(){throw Error('database secret')}}]) await assert.rejects(()=>readTermsAuthority({userId:1},db,raw),error=>error.message==='TERMS_AUTHORITY_UNAVAILABLE');
});
