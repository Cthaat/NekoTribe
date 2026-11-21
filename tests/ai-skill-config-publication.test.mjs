import assert from 'node:assert/strict';
import {test} from 'node:test';
import {build} from 'esbuild';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../',import.meta.url));
const stubs={'~/server/database/readiness':`export const requireFeatureSchema=async(c,f)=>{c.schema=f;if(c.unready)throw Error('secret')};`};
const built=await build({stdin:{contents:`export * from './server/services/ai/skill-config-publication.ts'`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'skill-publication-stubs',setup(b){b.onResolve({filter:/.*/},a=>Object.hasOwn(stubs,a.path)?{path:a.path,namespace:'stub'}:undefined);b.onLoad({filter:/.*/,namespace:'stub'},a=>({contents:stubs[a.path],loader:'js'}))}}]});
const {publishSkillConfig}=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);
function db({count=1,failWrite=false,failCommit=false}={}){return {calls:[],commits:0,rollbacks:0,async execute(sql,binds,options){this.calls.push({sql,binds,options});if(failWrite)throw Error('private');return {rowsAffected:count}},async commit(){this.commits++;if(failCommit)throw Error('private')},async rollback(){this.rollbacks++}}}
test('initial configuration and updates use generation checked transactions',async()=>{
 const first=db();const input=['writing-draft','knowledge-answer'];const out=await publishSkillConfig(first,{expectedGeneration:0,enabled:input});assert.equal(out.generation,1);assert.deepEqual(out.enabled,['knowledge-answer','writing-draft']);assert.equal(first.schema,'ai-skills');assert.match(first.calls[0].sql,/^INSERT\s+INTO\s+n_ai_skill_config/i);assert.equal(first.calls[0].options.autoCommit,false);assert.equal(first.calls[0].binds.enabled_ids,'["knowledge-answer","writing-draft"]');input.push('group-brief');assert.equal(out.enabled.length,2);
 const next=db();assert.deepEqual(await publishSkillConfig(next,{expectedGeneration:4,enabled:[]}),{generation:5,enabled:[]});assert.match(next.calls[0].sql,/generation\s*=\s*:expected_generation/i);assert.equal(next.calls[0].binds.enabled_ids,'[]');assert.equal(next.commits,1);
});
test('invalid input or stale generation cannot silently change settings',async()=>{
 for(const input of [{expectedGeneration:-1,enabled:[]},{expectedGeneration:1.5,enabled:[]},{expectedGeneration:999999999999999,enabled:[]},{expectedGeneration:0,enabled:['unknown']},{expectedGeneration:0,enabled:['writing-draft','writing-draft']},{expectedGeneration:0,enabled:null}]){const c=db();await assert.rejects(()=>publishSkillConfig(c,input),/SKILL_CONFIG_INVALID_INPUT/);assert.equal(c.calls.length,0)}
 const stale=db({count:0});await assert.rejects(()=>publishSkillConfig(stale,{expectedGeneration:2,enabled:[]}),/SKILL_CONFIG_CONFLICT/);assert.equal(stale.rollbacks,1);assert.equal(stale.commits,0);
});
test('write errors do not leak secrets and uncertain commit is never retried',async()=>{
 const bad=db({failWrite:true});await assert.rejects(()=>publishSkillConfig(bad,{expectedGeneration:0,enabled:[]}),e=>e.message==='SKILL_CONFIG_WRITE_FAILED');assert.equal(bad.rollbacks,1);
 const uncertain=db({failCommit:true});await assert.rejects(()=>publishSkillConfig(uncertain,{expectedGeneration:1,enabled:[]}),e=>e.message==='SKILL_CONFIG_COMMIT_UNCERTAIN');assert.equal(uncertain.calls.length,1);assert.equal(uncertain.commits,1);
});
test('a concurrent first publication returns a sanitized generation conflict',async()=>{
 const c=db();c.execute=async()=>{throw Object.assign(Error('private'),{errorNum:1})};
 await assert.rejects(()=>publishSkillConfig(c,{expectedGeneration:0,enabled:[]}),e=>e.message==='SKILL_CONFIG_CONFLICT');
 assert.equal(c.rollbacks,1);assert.equal(c.commits,0);
});
