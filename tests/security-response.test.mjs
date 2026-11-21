import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {build} from 'esbuild';
const root=fileURLToPath(new URL('../',import.meta.url));
const fixture=JSON.parse(readFileSync(new URL('../specifications/scenarios/auth-security-client-response-vectors.json',import.meta.url),'utf8'));
const built=await build({stdin:{contents:"export {v2StartTwoFactorSetup,v2ConfirmTwoFactorSetup,v2DisableTwoFactor,v2DeleteMe} from './app/services/account';",resolveDir:root,loader:'ts'},alias:{'@':root+'app','~':root+'app'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'security-response-transport',setup(b){
  b.onResolve({filter:/^(#app|@\/composables\/useApi)$/},args=>({path:args.path,namespace:'stub'}));
  b.onLoad({filter:/.*/,namespace:'stub'},({path})=>({contents:path==='#app'?'export const useNuxtApp=()=>globalThis.__securityOwner;':'export const apiFetch=async(path,options)=>{globalThis.__securityCalls.push({path,options});return globalThis.__securityReply;};'}));
}}]});
const api=await import('data:text/javascript;base64,'+Buffer.from(built.outputFiles[0].text).toString('base64'));
for(const c of fixture.cases)test('shared security response: '+c.id,async()=>{
  const body=structuredClone(Object.hasOwn(c,'root')?c.root:fixture.bases[c.operation]);
  for(const edit of c.changes){let node=body;for(const part of edit.path.slice(0,-1))node=node[part];if(edit.remove)delete node[edit.path.at(-1)];else node[edit.path.at(-1)]=edit.value;}
  globalThis.__securityOwner={runWithContext:action=>action()};globalThis.__securityReply=body;globalThis.__securityCalls=[];
  try{
    const pending=c.operation==='setup'?api.v2StartTwoFactorSetup({password:'x'}):c.operation==='confirm'?api.v2ConfirmTwoFactorSetup({code:'123456'}):c.operation==='disable'?api.v2DisableTwoFactor({password:'x',code:'123456'}):api.v2DeleteMe({password:'x',confirmation:'DELETE'});
    if(c.accepted){const result=await pending;assert(result);if(c.operation==='setup'){assert.equal(result.secret,body.data.secret);assert.equal(result.otpauthUrl,body.data.otpauth_url);}else if(c.operation==='confirm'){assert.equal(result.enabled,true);assert.deepEqual(result.recoveryCodes,body.data.recovery_codes);}else if(c.operation==='disable')assert.equal(result.enabled,false);else assert.deepEqual(result,{deleted:true,userId:body.data.user_id});}
    else await assert.rejects(pending,error=>error.message==='Invalid security action response');
    assert.equal(globalThis.__securityCalls.length,1);
  }finally{delete globalThis.__securityOwner;delete globalThis.__securityReply;delete globalThis.__securityCalls;}
});
