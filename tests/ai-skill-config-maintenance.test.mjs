import assert from 'node:assert/strict';
import {test} from 'node:test';
import {maintainSkills} from '../scripts/ai-skill-config-maintenance.mjs';
import {schemaFixture} from './helpers/schema-fixture.mjs';
import {applySchema} from '../server/database/schema.mjs';
const env={ORACLE_USER:'test',ORACLE_PASSWORD:'secret',ORACLE_HOST:'localhost',ORACLE_PORT:'1521',ORACLE_SERVICE_NAME:'test'};
test('plan is offline and publish requires explicit configuration and generation',async()=>{
 let drivers=0;const plan=await maintainSkills({args:['--plan','--enabled-json','["writing-draft"]'],loadDriver:async()=>{drivers++;throw Error()},output:()=>{}});assert.deepEqual(plan,{mode:'plan',enabled:['writing-draft'],connected:false});assert.equal(drivers,0);
 for(const args of [['--publish','--expected','0','--enabled-json','[]'],['--publish','--dotenv','x','--enabled-json','[]'],['--publish','--expected','0','--dotenv','x'],['--publish','--expected','1e3','--dotenv','x','--enabled-json','[]'],['--plan','--enabled-json','["evil"]'],['--plan','--enabled-json','null'],['--status','--dotenv','x','--enabled-json','[]']])await assert.rejects(()=>maintainSkills({args,loadDriver:async()=>{drivers++},output:()=>{}}));assert.equal(drivers,0);
});
test('publish and status use a dedicated connection with safe output',async()=>{
 let closes=0,publishes=0;const output=[];const connection={async execute(sql){assert.match(sql,/^SELECT/);return {rows:[{GENERATION:3,ENABLED_IDS:'["writing-draft"]'}]}},async close(){closes++}};
 const opts={env,readEnv:()=>({}),loadDriver:async()=>({OUT_FORMAT_OBJECT:4002,getConnection:async()=>connection}),output:s=>output.push(s)};
 const status=await maintainSkills({...opts,args:['--status','--dotenv','fixture']});assert.equal(status.generation,3);assert.deepEqual(status.enabled,['writing-draft']);
 const runtime={SkillRegistry:class {constructor(v){if(!Array.isArray(v))throw Error()}},async publishSkillConfig(c,input){assert.equal(c,connection);publishes++;assert.deepEqual(input,{expectedGeneration:3,enabled:[]});return {generation:4,enabled:[]}}};
 const result=await maintainSkills({...opts,args:['--publish','--expected','3','--enabled-json','[]','--dotenv','fixture'],loadRuntime:async()=>runtime});assert.equal(result.generation,4);assert.equal(publishes,1);assert.equal(closes,2);assert(!output.join('').includes('secret'));
});
test('uncertain commit is surfaced without retry and cleanup errors do not print success',async()=>{
 const output=[];let count=0;const runtime={SkillRegistry:class {},async publishSkillConfig(){count++;throw Error('SKILL_CONFIG_COMMIT_UNCERTAIN')}};
 const opts={env,readEnv:()=>({}),loadRuntime:async()=>runtime,loadDriver:async()=>({getConnection:async()=>({async close(){}})}),output:s=>output.push(s)};
 await assert.rejects(()=>maintainSkills({...opts,args:['--publish','--expected','1','--enabled-json','[]','--dotenv','x']}),e=>e.message==='SKILL_CONFIG_COMMIT_UNCERTAIN');assert.equal(count,1);assert.deepEqual(output,[]);
});
test('actual bundled publisher checks schema before writing',async()=>{
 const fixture=schemaFixture();await applySchema(fixture);let commits=0,writes=0;
 const connection={async execute(sql,binds,options){if(/^INSERT INTO n_ai_skill_config/i.test(sql)){writes++;assert.equal(options.autoCommit,false);assert.equal(binds.enabled_ids,'["writing-draft"]');return {rowsAffected:1}}return fixture.execute(sql,binds)},async commit(){commits++},async rollback(){throw Error('unexpected rollback')},async close(){}};
 const result=await maintainSkills({args:['--publish','--expected','0','--enabled-json','["writing-draft"]','--dotenv','fixture'],env,readEnv:()=>({}),loadDriver:async()=>({getConnection:async()=>connection}),output:()=>{}});
 assert.equal(result.generation,1);assert.equal(writes,1);assert.equal(commits,1);
});
