import assert from 'node:assert/strict';import {test} from 'node:test';import{readFileSync}from'node:fs';import{fileURLToPath}from'node:url';import{build}from'esbuild';
const root=fileURLToPath(new URL('../',import.meta.url)),fixture=JSON.parse(readFileSync(root+'specifications/scenarios/user-settings-client-response-vectors.json','utf8'));
const built=await build({stdin:{contents:"export {v2GetSettings,v2PatchSettings} from './app/services/account';",resolveDir:root,loader:'ts'},alias:{'@':root+'app','~':root+'app'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'settings-boundary',setup(b){
b.onResolve({filter:/^(#app|@\/composables\/useApi)$/},a=>({path:a.path,namespace:'stub'}));b.onLoad({filter:/.*/,namespace:'stub'},({path})=>({contents:path==='#app'?'export const useNuxtApp=()=>{throw Error("Unused auth operation");};':'export const apiFetch=async(path,options)=>{globalThis.__settingsCalls.push({path,options});return globalThis.__settingsReply;};'}));
}}]});
const api=await import('data:text/javascript;base64,'+Buffer.from(built.outputFiles[0].text).toString('base64'));
for(const operation of ['get','patch'])for(const c of fixture.cases)test('settings '+operation+': '+c.id,async()=>{
const body=structuredClone(Object.hasOwn(c,'root')?c.root:fixture.base);for(const e of c.changes){let n=body;for(const k of e.path.slice(0,-1))n=n[k];if(e.remove)delete n[e.path.at(-1)];else n[e.path.at(-1)]=e.value;}
globalThis.__settingsReply=body;globalThis.__settingsCalls=[];
try{const pending=operation==='get'?api.v2GetSettings():api.v2PatchSettings({loginAlerts:true});if(c.accepted){const result=await pending;assert.equal(result.userId,body.data.user_id);assert.equal(result.twoFactorEnabled,body.data.two_factor_enabled);assert.equal(result.loginAlerts,body.data.login_alerts);assert.equal(result.aiSentimentTopK,body.data.ai_sentiment_top_k);assert.equal(result.updatedAt,body.data.updated_at);}else await assert.rejects(pending,e=>e.message==='Invalid account settings response');assert.equal(globalThis.__settingsCalls.length,1);}finally{delete globalThis.__settingsReply;delete globalThis.__settingsCalls;}
});
