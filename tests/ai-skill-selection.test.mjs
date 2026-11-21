import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {test} from 'node:test';
import {build} from 'esbuild';
import {fileURLToPath} from 'node:url';

const root=fileURLToPath(new URL('../',import.meta.url));
const built=await build({stdin:{contents:`export * from './server/services/ai/skill-selection.ts'`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm'});
const {SkillRegistry}=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);
const vectors=JSON.parse(readFileSync(new URL('../specifications/scenarios/ai-skill-selection-vectors.json',import.meta.url),'utf8'));
test('shared selection vectors enforce enabled scope and authorization',async()=>{
 for(const row of vectors.cases){let calls=0;const run=async()=>{const registry=new SkillRegistry(row.enabled);return registry.select({actorId:7,purpose:row.purpose,groupId:row.groupId,skillId:row.skillId},async scope=>{calls++;assert.deepEqual(scope,{actorId:7,purpose:row.purpose,groupId:row.groupId});return row.allowed})};
  if(row.error)await assert.rejects(run,undefined,row.id);else {const result=await run();assert.equal(result.id,row.expected,row.id);assert.equal(result.version,1);assert.equal(result.selection,row.selection);assert.equal(result.groupId,row.groupId);assert.equal(calls,1)}
 }
});
test('authorization is checked for every selection; errors and invalid identities fail closed',async()=>{
 const registry=new SkillRegistry(['knowledge-answer']);let calls=0;const input={actorId:7,purpose:'knowledge',groupId:null,skillId:null};
 await registry.select(input,async()=>{calls++;return true});await assert.rejects(()=>registry.select(input,async()=>{calls++;throw Error('private')}),e=>e.message==='SKILL_UNAVAILABLE');assert.equal(calls,2);
 await assert.rejects(()=>registry.select({...input,actorId:0},async()=>{throw Error('not called')}),/SKILL_UNAVAILABLE/);
});
test('catalog and returned snapshots cannot be mutated into additional authority',async()=>{
 const enabled=['group-brief'],registry=new SkillRegistry(enabled);enabled.push('writing-draft');
 const input={actorId:7,purpose:'group',groupId:42,skillId:null};const first=await registry.select(input,async()=>true);first.tools.push('publish');
 const second=await registry.select(input,async()=>true);assert(!second.tools.includes('publish'));
 await assert.rejects(()=>registry.select({actorId:7,purpose:'writing',groupId:null,skillId:null},async()=>true),/SKILL_UNAVAILABLE/);
});
