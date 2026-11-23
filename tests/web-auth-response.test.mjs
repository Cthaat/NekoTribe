import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {build} from 'esbuild';

const root=fileURLToPath(new URL('../',import.meta.url));
const fixture=JSON.parse(readFileSync(new URL('../specifications/scenarios/auth-client-response-vectors.json',import.meta.url),'utf8'));
const built=await build({stdin:{contents:"export {v2Login,v2CompleteTwoFactorLogin,v2RefreshCurrentToken,v2CreateOtp,v2VerifyOtp,v2Register} from './app/services/auth';",resolveDir:root,loader:'ts'},alias:{'@':root+'app','~':root+'app'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'auth-response-boundary',setup(b){
  b.onResolve({filter:/^#app$/},()=>({path:'app',namespace:'stub'}));
  b.onResolve({filter:/^@\/api\/v2\/auth$/},()=>({path:'api',namespace:'stub'}));
  b.onResolve({filter:/^@\/utils\/assets$/},()=>({path:'assets',namespace:'stub'}));
  b.onResolve({filter:/^\.\/client$/},()=>({path:'other-api',namespace:'stub'}));
  b.onLoad({filter:/.*/,namespace:'stub'},({path})=>({contents:path==='app'?'export const useNuxtApp=()=>{throw Error("Unexpected unrelated app context");};':path==='assets'?'export const normalizeAvatarUrl=x=>x, normalizePublicMediaUrl=x=>x, normalizeNullableAssetUrl=x=>x;':path==='other-api'?['v2Request','v2RequestData','toV2PagedResult','v2SummaryMeta'].map(name=>`export const ${name}=()=>{throw Error('Unexpected unrelated API');};`).join('\n'):['v2CreateOtp','v2CompleteTwoFactorLogin','v2Login','v2LogoutCurrent','v2PasswordReset','v2RefreshCurrentToken','v2Register','v2VerifyOtp','v2ListSessions','v2RevokeOtherSessions'].map(name=>`export const ${name}=async()=>globalThis.__authResponse;`).join('\n')}));
}}]});
const api=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text+'\n//# sourceURL=auth-response-fixture.mjs\n').toString('base64')}`);
function input(vector){const value=structuredClone(fixture.bases[vector.base]);for(const change of vector.changes){let node=value;for(const part of change.path.slice(0,-1))node=node[part];const key=change.path.at(-1);if(change.remove)delete node[key];else node[key]=change.value;}return value;}

async function decode(operation,value){globalThis.__authResponse=value;try{return await (operation==='login'?api.v2Login({account:'synthetic',password:'synthetic'}):operation==='completion'?api.v2CompleteTwoFactorLogin({challengeId:'synthetic',code:'123456'}):api.v2RefreshCurrentToken());}finally{delete globalThis.__authResponse;}}
for(const vector of fixture.cases)test('shared auth response: '+vector.id,async()=>{
  const attempt=decode(vector.operation,input(vector));
  if(vector.expected==='reject'){await assert.rejects(attempt,error=>error.message==='Invalid authentication response');return;}
  const result=await attempt;
  if(vector.expected==='challenge'){assert.equal(result.twoFactorRequired,true);assert.equal(result.challengeId,'synthetic-challenge');}
  else if(vector.operation==='refresh'){assert.equal(result.sessionId,'synthetic-session');assert(!('accessToken' in result));assert(!('refreshToken' in result));}
  else{assert.equal(result.user.id,1);assert.equal(result.tokens.sessionId,'synthetic-session');}
});
const publicFixture=JSON.parse(readFileSync(new URL('../specifications/scenarios/auth-public-response-vectors.json',import.meta.url),'utf8'));
for(const operation of ['create','verify','register'])test(`${operation} response validation uses the captured request, not an edited form`,async()=>{
  let resolve;globalThis.__authResponse=new Promise(r=>{resolve=r;});
  const form={account:publicFixture.account,type:'register',channel:'email',verificationId:'synthetic-otp',code:'123456',email:publicFixture.account,username:publicFixture.username,displayName:'Synthetic',password:'synthetic',confirmPassword:'synthetic',agreeToTerms:true};
  try{
    const pending=operation==='create'?api.v2CreateOtp(form):operation==='verify'?api.v2VerifyOtp(form):api.v2Register(form);
    form.account='changed@example.test';form.email=form.account;form.username='changed';
    resolve(structuredClone(publicFixture.bases[operation]));await pending;
  }finally{delete globalThis.__authResponse;}
});
for(const vector of publicFixture.cases)test('shared public auth: '+vector.id,async()=>{
  const data=structuredClone(publicFixture.bases[vector.operation]);
  for(const edit of vector.changes){let node=data;for(const part of edit.path.slice(0,-1))node=node[part];if(edit.remove)delete node[edit.path.at(-1)];else node[edit.path.at(-1)]=edit.value;}
  globalThis.__authResponse=data;
  try{
    const pending=vector.operation==='create'?api.v2CreateOtp({account:publicFixture.account,type:'register',channel:'email'}):vector.operation==='verify'?api.v2VerifyOtp({account:publicFixture.account,type:'register',verificationId:'synthetic-otp',code:'123456'}):api.v2Register({email:publicFixture.account,username:publicFixture.username,displayName:'Synthetic',password:'synthetic',confirmPassword:'synthetic',verificationId:'synthetic-otp',agreeToTerms:true});
    if(!vector.accepted){await assert.rejects(pending,error=>error.message==='Invalid authentication response');return;}
    const result=await pending;if(vector.operation==='register'){assert.equal(result.user.id,1);assert.equal(result.user.email,publicFixture.account);assert(!('tokens' in result));}else{assert.equal(result.account,publicFixture.account);if(vector.operation==='verify')assert.equal(result.verified,true);}
  }finally{delete globalThis.__authResponse;}
});
for(const operation of ['login','completion','refresh'])test(`${operation} rejects malformed root and token types without leaking values`,async()=>{
  for(const value of [null,[],false,123,'synthetic-secret'])await assert.rejects(decode(operation,value),error=>error.message==='Invalid authentication response');
  if(operation==='refresh')for(const value of [null,123,{},[],false,' ']){const payload=structuredClone(fixture.bases.refresh);payload.access_token=value;await assert.rejects(decode(operation,payload),error=>error.message==='Invalid authentication response');}
});
