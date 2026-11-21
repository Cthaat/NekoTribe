import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {test} from 'node:test';
import {build} from 'esbuild';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../',import.meta.url));
const built=await build({stdin:{contents:`export * from './server/services/ai/public-terms-source.ts';export * from './app/utils/public-terms-reference.ts'`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm'});
const {parseTermsCatalog,discoverPublicTerms,hydratePublicTerms,resolvePublicTermsReference}=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);
const raw=JSON.parse(readFileSync(new URL('../specifications/requirements/ai-public-terms-catalog.json',import.meta.url),'utf8'));
test('matches independent cross-language version and exact-search vectors',()=>{
 const vectors=JSON.parse(readFileSync(new URL('../specifications/scenarios/ai-public-terms-source-vectors.json',import.meta.url),'utf8'));
 const catalog=parseTermsCatalog(raw);
 assert.deepEqual(catalog.map(({id,version})=>({id,version})),vectors.versions);
 for(const row of vectors.searches) assert.deepEqual(discoverPublicTerms(catalog,row.query,row.limit).map(x=>x.id),row.ids);
});
test('public terms search and revalidation use stable IDs and invalidate changed versions',()=>{
 const catalog=parseTermsCatalog(raw);
 const found=discoverPublicTerms(catalog,'账户',20);
 assert.deepEqual(found.map(x=>x.id),[2]);
 assert.equal(found[0].kind,'terms');assert.equal(found[0].href,'/zh/auth/terms#accounts');assert.match(found[0].version,/^[a-f0-9]{64}$/);
 const ref={kind:'terms',id:found[0].id,version:found[0].version};
 assert.deepEqual(hydratePublicTerms(catalog,[ref]),found);
 const changed=structuredClone(raw);changed.documents[1].blocks[0]+='修改';
 assert.deepEqual(hydratePublicTerms(parseTermsCatalog(changed),[ref]),[]);
});
test('web resolves only the cited version and locale from its bundled terms',()=>{
 const catalog=parseTermsCatalog(raw), item=catalog[2], cite=`${item.id}.${item.version}`;
 assert.deepEqual(resolvePublicTermsReference(catalog,cite,'zh'),item);
 assert.equal(resolvePublicTermsReference(catalog,[cite,cite],'zh'),null);
 assert.equal(resolvePublicTermsReference(catalog,cite+'\n','zh'),null);
 assert.equal(resolvePublicTermsReference(catalog,cite,'en'),null);
 const changed=structuredClone(raw);
 changed.documents[2].blocks[0]+='修改';
 assert.equal(resolvePublicTermsReference(parseTermsCatalog(changed),cite,'zh'),null);
});
test('invalid or ambiguous catalog and reference inputs fail closed',()=>{
 const catalog=parseTermsCatalog(raw);
 const bad=structuredClone(raw);bad.documents[1].href='https://example.com';assert.throws(()=>parseTermsCatalog(bad),/INVALID_CATALOG/);
 const duplicate=structuredClone(raw);duplicate.documents[1]=duplicate.documents[0];assert.throws(()=>parseTermsCatalog(duplicate),/INVALID_CATALOG/);
 for(const term of ['', '\0', 'x'.repeat(257)]) assert.throws(()=>discoverPublicTerms(catalog,term,10),/INVALID_QUERY/);
 assert.throws(()=>hydratePublicTerms(catalog,[{kind:'terms',id:1,version:'a'.repeat(64)},{kind:'terms',id:1,version:'a'.repeat(64)}]),/INVALID_REFERENCE/);
});
