import assert from 'node:assert/strict';
import {test} from 'node:test';
import {build} from 'esbuild';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../',import.meta.url));
const stubs={'~/server/utils/v2':`export const v2Auth=e=>{if(!e.userId)throw Error('401');return {userId:e.userId}};`, './conversation-access':`export async function authorizeConversationScope(e,c,scope){c.checks.push(scope);if(scope.ownerUserId!==e.userId || !c.allowed)throw Error('403')}`,'./skill-config-store':`import {SkillRegistry} from './server/services/ai/skill-selection.ts';export async function loadSkillRegistry(e,c){if(!e.userId)throw Error('401');c.loads++;return {generation:c.generation,registry:new SkillRegistry(c.enabled)}}`};
const built=await build({stdin:{contents:`export * from './server/services/ai/skill-conversation.ts';export {SkillRegistry} from './server/services/ai/skill-selection.ts'`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'skill-stubs',setup(b){b.onResolve({filter:/.*/},a=>Object.hasOwn(stubs,a.path)?{path:a.path,namespace:'stub'}:undefined);b.onLoad({filter:/.*/,namespace:'stub'},a=>({contents:stubs[a.path],resolveDir:root,loader:'js'}))}}]});
const {selectConversationSkill,selectConfiguredConversationSkill,SkillRegistry}=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);
test('uses authenticated owner and current backend conversation permissions',async()=>{
 const registry=new SkillRegistry(['group-brief']),connection={checks:[],allowed:true};
 const selected=await selectConversationSkill({userId:7},connection,registry,{ownerUserId:7,purpose:'group',groupId:42},null);
 assert.equal(selected.id,'group-brief');assert.equal(selected.actorId,7);assert.deepEqual(connection.checks,[{ownerUserId:7,purpose:'group',groupId:42}]);
 connection.allowed=false;await assert.rejects(()=>selectConversationSkill({userId:7},connection,registry,{ownerUserId:7,purpose:'group',groupId:42},null),/SKILL_UNAVAILABLE/);
 await assert.rejects(()=>selectConversationSkill({userId:8},connection,registry,{ownerUserId:7,purpose:'group',groupId:42},null),/SKILL_UNAVAILABLE/);
 await assert.rejects(()=>selectConversationSkill({},connection,registry,{ownerUserId:7,purpose:'group',groupId:42},null),/401/);
});
test('selection reloads durable settings per request and returns the configuration generation',async()=>{
 const connection={checks:[],allowed:true,loads:0,generation:2,enabled:['writing-draft']};const scope={ownerUserId:7,purpose:'writing',groupId:null};
 const result=await selectConfiguredConversationSkill({userId:7},connection,scope,null);assert.equal(result.configGeneration,2);assert.equal(result.skill.id,'writing-draft');
 connection.enabled=[];connection.generation=3;await assert.rejects(()=>selectConfiguredConversationSkill({userId:7},connection,scope,null),/SKILL_UNAVAILABLE/);assert.equal(connection.loads,2);
});
