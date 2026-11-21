import assert from 'node:assert/strict';
import {test} from 'node:test';
import {build} from 'esbuild';
import {fileURLToPath} from 'node:url';
import {readFileSync} from 'node:fs';
const root=fileURLToPath(new URL('../',import.meta.url));
const stubs={
  '~/server/utils/v2':`export const v2Auth=e=>{if(!e.user)throw Error('401');return {userId:42}};export const v2Ok=data=>({code:200,message:'success',data,meta:null});`,
  './skill-config-store':`import {SkillRegistry} from './server/services/ai/skill-selection.ts';export async function loadSkillRegistry(e,c){c.calls++;if(c.fail)throw Error('database secret');return {registry:new SkillRegistry(c.enabled),generation:1}}`
};
const result=await build({stdin:{contents:`export {readAIAvailability, readInferenceAvailability} from './server/services/ai/availability';`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'availability-stubs',setup(b){b.onResolve({filter:/.*/},a=>Object.hasOwn(stubs,a.path)?{path:a.path,namespace:'stub'}:undefined);b.onLoad({filter:/.*/,namespace:'stub'},a=>({contents:stubs[a.path],resolveDir:root,loader:'js'}))}}]});
const {readAIAvailability, readInferenceAvailability}=await import(`data:text/javascript;base64,${Buffer.from(result.outputFiles[0].text).toString('base64')}`);

test('inference status checks each enabled role without probing the model', async t => {
  const config = JSON.parse(readFileSync(new URL('../specifications/scenarios/ai-model-config.json', import.meta.url))).cases[0].config;
  config.bindings.writing = 'capable';
  const keys = ['AI_MODEL_CONFIG_FILE', 'AI_MODEL_CONFIG_JSON', 'AI_HOSTED_KEY'];
  for (const key of keys) {
    const original = process.env[key];
    t.after(() => { if (original === undefined) delete process.env[key]; else process.env[key] = original; });
  }
  delete process.env.AI_MODEL_CONFIG_FILE;
  delete process.env.AI_HOSTED_KEY;
  process.env.AI_MODEL_CONFIG_JSON = JSON.stringify(config);
  const enabled = { knowledge: true, writing: true, group: true, moderation: true };
  const missingKey = {
    inference: { knowledge: true, writing: false, group: false, moderation: false },
    model_config_revision: config.revision
  };
  assert.deepEqual(await readInferenceAvailability(enabled), missingKey);
  process.env.AI_HOSTED_KEY = 'a bad value';
  assert.deepEqual(await readInferenceAvailability(enabled), missingKey);
  process.env.AI_HOSTED_KEY = 'fixture-key';
  assert.deepEqual(await readInferenceAvailability({ ...enabled, knowledge: false }), {
    inference: { knowledge: false, writing: true, group: true, moderation: true },
    model_config_revision: config.revision
  });
  const disabled = { knowledge: false, writing: false, group: false, moderation: false };
  assert.deepEqual(await readInferenceAvailability(disabled), { inference: disabled, model_config_revision: config.revision });
  delete process.env.AI_MODEL_CONFIG_JSON;
  assert.deepEqual(await readInferenceAvailability(disabled), { inference: disabled, model_config_revision: null });
});
test('matches the shared cross-backend availability cases',async()=>{
 const fixture=JSON.parse(readFileSync(new URL('../specifications/scenarios/ai-availability.json',import.meta.url),'utf8'));
 assert.equal(fixture.id,'AI-AVAILABILITY');
 for(const vector of fixture.cases) {
  const db={calls:0,enabled:vector.enabled,fail:vector.unavailable};
  if(vector.status===200) assert.deepEqual((await readAIAvailability({user:vector.authenticated},db)).data,vector.data,vector.id);
  else await assert.rejects(()=>readAIAvailability({user:vector.authenticated},db),error=>vector.status===401?/401/.test(error.message):error.statusCode===503,vector.id);
  if(!vector.authenticated) assert.equal(db.calls,0,vector.id);
 }
});
test('returns only feature flags for authenticated users',async()=>{
 for(const [enabled,expected] of [[[],{knowledge:false,writing:false,group:false,moderation:false}],[['writing-draft','group-brief','moderation-advice'],{knowledge:false,writing:true,group:true,moderation:true}]]) {
  const db={calls:0,enabled};const response=await readAIAvailability({user:true},db);assert.deepEqual(response.data,expected);assert.equal(db.calls,1);
 }
 const db={calls:0,enabled:[]};await assert.rejects(()=>readAIAvailability({},db),/401/);assert.equal(db.calls,0);
});
test('unavailable or corrupt configuration returns sanitized 503',async()=>{
 for(const db of [{calls:0,fail:true},{calls:0,enabled:['unknown']}]) {
  await assert.rejects(()=>readAIAvailability({user:true},db),error=>error.statusCode===503 && error.data.code===50301 && !JSON.stringify(error.data).includes('secret'));
 }
});
