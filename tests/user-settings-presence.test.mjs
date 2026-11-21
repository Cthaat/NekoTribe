import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFileSync} from 'node:fs';
import {routes,request} from './helpers/settings-http.mjs';
const vectors=JSON.parse(readFileSync(new URL('../specifications/scenarios/user-settings-presence.json',import.meta.url)));
for(const vector of vectors.cases)test('Nuxt presence HTTP '+vector.id,async()=>{
 const result=await request({method:'PATCH',mode:vector.mode,body:vector.body});
 assert.equal(result.status,vector.status);
 assert.equal(result.headers.get('cache-control'),'private, no-store');
 assert.equal(result.state.presence,vector.reads);
 assert.equal(result.state.publishes.length,vector.publishes);
 assert(!JSON.stringify(result.body).includes('synthetic-settings-driver-secret'));
 if(vector.expectedStatus){
  const event=result.state.publishes[0];
  assert.equal(event.channel,'ws:presence');
  assert.equal(event.message.type,'presence_update');
  assert.deepEqual(event.message.data,{user_id:42,online_status:vector.expectedStatus,last_seen_at:vector.expectedLastSeen,server_id:'test-instance'});
  assert(Number.isSafeInteger(event.message.timestamp));
 }
 if(vector.id==='lookup-failed-after-commit'){assert.equal(result.state.commits,1);assert.equal(result.state.rollbacks,0);}
});
for(const vector of vectors.queryCases)test('Nuxt presence query '+vector.id,async()=>{
 const db={async execute(sql,binds){
  assert.match(sql,/FROM n_users u/);assert.match(sql,/revoked_at IS NULL/);
  assert.equal(binds.user_id,42);assert.equal(binds.online_window_seconds,90);
  return{rows:vector.missing?[]:[{SHOW_ONLINE_STATUS:vector.flag,ONLINE_STATUS:vector.status,LAST_SEEN_AT:vector.lastSeen}]};
 }};
 if(vector.error)await assert.rejects(()=>routes.v2GetUserPresence(db,42));
 else assert.deepEqual(await routes.v2GetUserPresence(db,42),{user_id:42,online_status:vector.expectedStatus,last_seen_at:vector.expectedLastSeen});
});
for(const vector of vectors.eventCases)test('Nuxt presence event '+vector.id,()=>{
 assert.equal(typeof routes.v2PresenceMessage,'function','Standalone fixed event envelope required');
 if(!vector.valid)assert.throws(()=>routes.v2PresenceMessage(vector.data,vector.serverId,vector.timestamp));
 else assert.deepEqual(routes.v2PresenceMessage(vector.data,vector.serverId,vector.timestamp),{type:'presence_update',data:{user_id:vector.data.user_id,online_status:vector.data.online_status,last_seen_at:vector.data.online_status==='hidden'?null:vector.data.last_seen_at,server_id:vector.serverId},timestamp:vector.timestamp});
});
test('Nuxt local WS failure does not suppress the independent Redis publication or the saved response',async()=>{
 const result=await request({method:'PATCH',mode:'local-error',body:{show_online_status:true}});
 assert.equal(result.status,200);assert.equal(result.state.localMessages.length,1);assert.equal(result.state.publishes.length,1);
});
test('Nuxt invalid publication clock is a delivery failure after a valid presence lookup',async()=>{
 const originalNow=Date.now,previous=globalThis.__settingsPresence;let attempts=0;
 globalThis.__settingsPresence={local(){attempts++;},redis(){attempts++;}};
 Date.now=()=>-1;
 try{
  const value=await routes.v2PublishUserPresence({async execute(){return{rows:[{SHOW_ONLINE_STATUS:1,ONLINE_STATUS:'online',LAST_SEEN_AT:null}]};}},42);
  assert.equal(value.online_status,'online');assert.equal(attempts,0);
 }finally{Date.now=originalNow;globalThis.__settingsPresence=previous;}
});
