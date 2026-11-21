import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {build} from 'esbuild';
const root=fileURLToPath(new URL('../',import.meta.url));
const fixture=JSON.parse(readFileSync(new URL('../specifications/scenarios/auth-email-client-response-vectors.json',import.meta.url),'utf8'));
const built=await build({stdin:{contents:"export {v2ChangeEmail} from './app/services/users';",resolveDir:root,loader:'ts'},alias:{'@':root+'app','~':root+'app'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'email-transport',setup(b){
 b.onResolve({filter:/^#app$/},()=>({path:'app',namespace:'stub'}));
 b.onResolve({filter:/^@\/composables\/useApi$/},()=>({path:'transport',namespace:'stub'}));
 b.onResolve({filter:/^@\/utils\/assets$/},()=>({path:'assets',namespace:'stub'}));
 b.onLoad({filter:/.*/,namespace:'stub'},({path})=>({contents:path==='app'?'export const useNuxtApp=()=>{throw Error("Not needed for email response");};':path==='assets'?'export const normalizeAvatarUrl=x=>x;':'export const apiFetch=async(path,options)=>{globalThis.__emailCalls.push({path,options});return globalThis.__emailReply;};'}));
}}]});
const api=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text+'\n//# sourceURL=email-response-fixture.mjs\n').toString('base64')}`);
for(const c of fixture.cases)test('email response: '+c.id,async()=>{
 const body=Object.hasOwn(c,'root')?structuredClone(c.root):structuredClone(fixture.base);
 for(const edit of c.changes){let node=body;for(const part of edit.path.slice(0,-1))node=node[part];if(edit.remove)delete node[edit.path.at(-1)];else node[edit.path.at(-1)]=edit.value;}
 globalThis.__emailReply=body;globalThis.__emailCalls=[];
 try{
  const pending=api.v2ChangeEmail({newEmail:fixture.account,verificationId:'synthetic-otp',code:'123456'});
  if(c.accepted){const result=await pending;assert.equal(result.email,fixture.account);assert.equal(result.emailVerifiedAt,body.data.email_verified_at);}
  else await assert.rejects(pending,e=>e.message==='Invalid email change response');
  assert.equal(globalThis.__emailCalls.length,1);
 }finally{delete globalThis.__emailReply;delete globalThis.__emailCalls;}
});
test('email response compares against the submitted snapshot',async()=>{
 let resolve;globalThis.__emailReply=new Promise(r=>{resolve=r;});globalThis.__emailCalls=[];
 const form={newEmail:' new@example.test ',verificationId:'synthetic-otp',code:'123456'};
 try{const pending=api.v2ChangeEmail(form);form.newEmail='different@example.test';resolve(structuredClone(fixture.base));assert.equal((await pending).email,fixture.account);assert.equal(globalThis.__emailCalls[0].options.body.new_email,' new@example.test ');}
 finally{delete globalThis.__emailReply;delete globalThis.__emailCalls;}
});
