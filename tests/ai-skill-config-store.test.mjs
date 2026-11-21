import assert from 'node:assert/strict';
import {test} from 'node:test';
import {build} from 'esbuild';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../',import.meta.url));
const stubs={'oracledb':`export default {OUT_FORMAT_OBJECT:4002};`,'~/server/database/readiness':`export const requireFeatureSchema=async(c,f)=>{c.schema=f;if(c.unready)throw Error('secret')};`,'~/server/utils/v2':`export const v2Auth=e=>{if(!e.userId)throw Error('401');return {userId:e.userId}};`};
const built=await build({stdin:{contents:`export * from './server/services/ai/skill-config-store.ts'`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'skill-config-stubs',setup(b){b.onResolve({filter:/.*/},a=>Object.hasOwn(stubs,a.path)?{path:a.path,namespace:'stub'}:undefined);b.onLoad({filter:/.*/,namespace:'stub'},a=>({contents:stubs[a.path],loader:'js'}))}}]});
const {loadSkillRegistry,lockSkillRegistry}=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);
test('transactional validation locks configuration without committing',async()=>{
 let commits=0,rollbacks=0;const calls=[];
 const db={async execute(sql){calls.push(sql);return {rows:[{GENERATION:7,ENABLED_IDS:'["knowledge-answer"]'}]}},async commit(){commits++},async rollback(){rollbacks++}};
 const result=await lockSkillRegistry({userId:7},db);assert.equal(result.generation,7);assert.match(calls[0],/FOR UPDATE NOWAIT\s*$/i);assert.equal(commits,0);assert.equal(rollbacks,0);
 const denied={async execute(){throw Error('sensitive lock error')}};
 await assert.rejects(()=>lockSkillRegistry({userId:7},denied),error=>error.message==='SKILL_CONFIG_UNAVAILABLE');
});
test('authenticated reads use current durable config for each selection',async()=>{
 let enabled='["writing-draft"]',calls=0;const db={async execute(sql,binds,options){calls++;assert.match(sql,/FROM\s+n_ai_skill_config/i);assert.deepEqual(binds,{singleton_id:1});assert.equal(options.outFormat,4002);return {rows:[{GENERATION:calls,ENABLED_IDS:enabled}]}}};
 const a=await loadSkillRegistry({userId:7},db);assert.equal(a.generation,1);assert.equal(db.schema,'ai-skills');assert.equal((await a.registry.select({actorId:7,purpose:'writing',groupId:null,skillId:null},async()=>true)).id,'writing-draft');
 enabled='[]';const b=await loadSkillRegistry({userId:7},db);assert.equal(b.generation,2);await assert.rejects(()=>b.registry.select({actorId:7,purpose:'writing',groupId:null,skillId:null},async()=>true));
 await assert.rejects(()=>loadSkillRegistry({},db),/401/);assert.equal(calls,2);
});
test('missing, malformed, duplicated, oversized or unavailable configuration fails closed',async()=>{
 const valid={GENERATION:1,ENABLED_IDS:'[]'};
 for(const rows of [[],[valid,valid],[{...valid,GENERATION:0}],[{...valid,GENERATION:1.5}],[{...valid,GENERATION:1e15}],[{...valid,ENABLED_IDS:'invalid'}],[{...valid,ENABLED_IDS:'["writing-draft","writing-draft"]'}],[{...valid,ENABLED_IDS:'["unknown"]'}],[{...valid,ENABLED_IDS:' '.repeat(513)}]]){
  await assert.rejects(()=>loadSkillRegistry({userId:7},{async execute(){return {rows}}}),e=>e.message==='SKILL_CONFIG_UNAVAILABLE');
 }
 for(const db of [{unready:true},{async execute(){throw Error('secret')}}])await assert.rejects(()=>loadSkillRegistry({userId:7},db),e=>e.message==='SKILL_CONFIG_UNAVAILABLE');
});
