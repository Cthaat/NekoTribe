import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {test} from 'node:test';
import {build} from 'esbuild';
import {fileURLToPath} from 'node:url';

const root=fileURLToPath(new URL('../',import.meta.url));
const stubs={oracledb:`export default {OUT_FORMAT_OBJECT:4002};`, '~/server/database/readiness':`export const requireFeatureSchema=async(db,feature)=>{db.schema=feature;if(db.unready)throw Error('secret')};`, '~/server/utils/v2':`export const v2Auth=()=>{};`};
const built=await build({stdin:{contents:`export * from './server/services/ai/public-terms-publication.ts'`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'publication-stubs',setup(b){b.onResolve({filter:/.*/},a=>Object.hasOwn(stubs,a.path)?{path:a.path,namespace:'stub'}:undefined);b.onLoad({filter:/.*/,namespace:'stub'},a=>({contents:stubs[a.path],loader:'js'}))}}]});
const {changeTermsAuthority}=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);
const catalog=JSON.parse(readFileSync(new URL('../specifications/requirements/ai-public-terms-catalog.json',import.meta.url),'utf8'));
const expected=JSON.parse(readFileSync(new URL('../specifications/scenarios/ai-public-terms-source-vectors.json',import.meta.url),'utf8')).catalog_digest;
function db({rowsAffected=1,executeError,commitError}={}) {return {calls:[],commits:0,rollbacks:0,async execute(sql,binds,options){this.calls.push({sql,binds,options});if(executeError)throw Error('secret');return {rowsAffected}},async commit(){this.commits++;if(commitError)throw Error('secret')},async rollback(){this.rollbacks++}}}
test('initial publication and versioned replacement use bounded atomic writes',async()=>{
 const first=db();assert.deepEqual(await changeTermsAuthority(first,{action:'publish',expectedGeneration:0,catalog}),{generation:1,digest:expected,enabled:true});
 assert.equal(first.schema,'ai-terms');assert.match(first.calls[0].sql,/^INSERT\s+INTO\s+n_ai_terms_active/i);assert.equal(first.calls[0].binds.digest,expected);assert.equal(first.calls[0].options.autoCommit,false);assert.equal(first.commits,1);
 const next=db();assert.deepEqual(await changeTermsAuthority(next,{action:'publish',expectedGeneration:3,catalog}),{generation:4,digest:expected,enabled:true});
 assert.match(next.calls[0].sql,/^UPDATE\s+n_ai_terms_active/i);assert.match(next.calls[0].sql,/generation\s*=\s*:expected_generation/i);assert.equal(next.calls[0].binds.expected_generation,3);assert.equal(next.commits,1);
});
test('disable increments the version, does not change digest and rejects missing or stale rows',async()=>{
 const c=db();assert.deepEqual(await changeTermsAuthority(c,{action:'disable',expectedGeneration:2}),{generation:3,enabled:false});assert.match(c.calls[0].sql,/enabled\s*=\s*0/i);assert.doesNotMatch(c.calls[0].sql,/catalog_digest\s*=/i);
 const stale=db({rowsAffected:0});await assert.rejects(()=>changeTermsAuthority(stale,{action:'disable',expectedGeneration:2}),/TERMS_AUTHORITY_CONFLICT/);assert.equal(stale.commits,0);assert.equal(stale.rollbacks,1);
});
test('invalid input never writes; errors fail closed and unknown commit is not retried',async()=>{
 for(const input of [{action:'disable',expectedGeneration:0},{action:'publish',expectedGeneration:1.5,catalog},{action:'publish',expectedGeneration:999999999999999,catalog},{action:'publish',expectedGeneration:0,catalog:{}}]){const c=db();await assert.rejects(()=>changeTermsAuthority(c,input));assert.equal(c.calls.length,0)}
 const unavailable=db({executeError:true});await assert.rejects(()=>changeTermsAuthority(unavailable,{action:'publish',expectedGeneration:0,catalog}),error=>error.message==='TERMS_AUTHORITY_WRITE_FAILED');assert.equal(unavailable.rollbacks,1);
 const uncertain=db({commitError:true});await assert.rejects(()=>changeTermsAuthority(uncertain,{action:'disable',expectedGeneration:1}),error=>error.message==='TERMS_AUTHORITY_COMMIT_UNCERTAIN');assert.equal(uncertain.commits,1);assert.equal(uncertain.calls.length,1);
});
