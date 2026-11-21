import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {build} from 'esbuild';
const built=await build({entryPoints:[fileURLToPath(new URL('../server/utils/realtime-subscription.ts',import.meta.url))],bundle:true,write:false,platform:'node',format:'esm'});
const api=await import('data:text/javascript;base64,'+Buffer.from(built.outputFiles[0].text).toString('base64'));
test('broker event admission follows the shared contract',()=>{
 const fixture=JSON.parse(readFileSync(new URL('../specifications/scenarios/notification-websocket.json',import.meta.url)));
 for(const entry of fixture.brokerCases) {
  assert.equal(api.allowRealtimeFrame(entry.channel,entry.raw,42,'local'),entry.valid,entry.id);
 }
});
const tick=()=>new Promise(resolve=>setImmediate(resolve));
async function waitFor(predicate){const end=Date.now()+2500;while(!predicate()){assert(Date.now()<end,'condition timed out');await new Promise(resolve=>setTimeout(resolve,5));}}
class Transport {
  mode='healthy'; closed=0; connects=0; subscribed=[]; unsubscribed=[];
  async connect(message,lost){this.connects++;this.message=message;this.lost=lost;if(this.mode==='failed')throw Error('private-driver-detail');if(this.mode==='pending')await new Promise(resolve=>{this.release=resolve;});}
  async subscribe(channels){this.subscribed.push([...channels]);}
  async unsubscribe(channels){this.unsubscribed.push([...channels]);}
  close(){this.closed++;}
}
function create(transports=[new Transport()]){
  const states=[],messages=[],created=[];
  const source=api.createRealtimeSubscription({userId:42,serverId:'local',createTransport:()=>{const transport=transports[created.length]??new Transport();created.push(transport);return transport;},onState:state=>states.push(state),onMessage:raw=>messages.push(raw)});
  return{source,states,messages,created};
}
test('connection status remains connecting until remote subscriptions are acknowledged',async()=>{
 const transport=new Transport();transport.mode='pending';const state=create([transport]);
 try{
  assert.deepEqual(state.states,['connecting']);await tick();assert.equal(state.created.length,1);
  assert.deepEqual(state.states,['connecting']);transport.release();await waitFor(()=>state.states.at(-1)==='connected');
  assert.deepEqual(new Set(transport.subscribed.flat()),new Set(['ws:user:42','ws:presence','ws:broadcast','ws:system']));
 }finally{state.source.close();}
});
test('remote failure reports unavailable and retries without keeping old transport alive',async()=>{
 const failed=new Transport();failed.mode='failed';const state=create([failed]);
 try{
  await waitFor(()=>state.states.at(-1)==='unavailable');assert.equal(failed.closed,1);
  await waitFor(()=>state.states.at(-1)==='connected');assert.equal(state.created.length,2);
 }finally{state.source.close();}
});

test('close between attempt creation and connect does not start canceled I/O',async()=>{
 const transport=new Transport();const state=create([transport]);queueMicrotask(()=>state.source.close());
 await tick();assert.equal(transport.closed,1);assert.equal(transport.connects,0);assert.deepEqual(state.states,['connecting']);
});
test('channel change from the connected callback is reconciled after the current pass',async()=>{
 const transport=new Transport();let source;let changed=false;
 source=api.createRealtimeSubscription({userId:42,serverId:'local',createTransport:()=>transport,onMessage:()=>{},onState:state=>{if(state==='connected'&&!changed){changed=true;source.joinChat(7);}}});
 try{await tick();assert(transport.subscribed.flat().includes('ws:chat:channel:7'),'callback mutation was lost');}
 finally{source.close();}
});

test('shared presence frames are strict, broker health is rejected and raw notifications retain bytes',async()=>{
 const fixture=JSON.parse(readFileSync(new URL('../specifications/scenarios/local-presence.json',import.meta.url)));
 for(const item of fixture.remoteCases)assert.equal(api.allowRealtimeFrame('ws:presence',JSON.stringify(item.frame),42,'local'),item.valid,item.id);
 for(const item of fixture.statusCases){const raw=JSON.stringify({type:'system_notification',data:{code:'realtime_status',user_id:42,server_id:'peer',local_presence:item.local_presence,remote_events:item.remote_events},timestamp:1});for(const channel of ['ws:user:42','ws:presence','ws:broadcast','ws:system'])assert.equal(api.allowRealtimeFrame(channel,raw,42,'local'),false,item.id);}
 const transport=new Transport(),state=create([transport]);
 try{
  await waitFor(()=>state.states.at(-1)==='connected');
  const raw=String.raw`{"type":"notification_created","data":{"server_id":"local","text":"prefix\ud83d..."},"timestamp":1}`;
  transport.message('ws:user:9',raw);transport.message('ws:broadcast',raw);
  transport.message('ws:presence',JSON.stringify({type:'presence_update',data:{user_id:9,online_status:'hidden',last_seen_at:null,server_id:'local'},timestamp:1}));
  assert.equal(state.messages.length,0);transport.message('ws:user:42',raw);assert.deepEqual(state.messages,[raw]);
  for(const raw of ['not json',JSON.stringify({type:'notification_created',data:[],timestamp:1}),'x'.repeat(262145)])transport.message('ws:user:42',raw);
  assert.deepEqual(state.messages,[raw]);
 }finally{state.source.close();}
});

test('early messages wait for acknowledgment and stale attempt callbacks cannot deliver or recover',async()=>{
 const first=new Transport();let acknowledge;
 first.subscribe=async channels=>{first.subscribed.push([...channels]);await new Promise(resolve=>{acknowledge=resolve;});};
 const state=create([first]);
 const raw=JSON.stringify({type:'notification_created',data:{id:1},timestamp:1});
 try{
  await waitFor(()=>typeof acknowledge==='function');first.message('ws:user:42',raw);assert.deepEqual(state.messages,[]);
  acknowledge();await waitFor(()=>state.states.at(-1)==='connected');assert.deepEqual(state.messages,[raw]);
  first.lost();assert.equal(state.states.at(-1),'unavailable');await waitFor(()=>state.created.length===2&&state.states.at(-1)==='connected');
  first.message('ws:user:42',raw);first.lost();assert.deepEqual(state.messages,[raw]);assert.equal(state.states.at(-1),'connected');
 }finally{state.source.close();}
});

test('closing a pending attempt releases it and late completion does not subscribe or retry',async()=>{
 const transport=new Transport();transport.mode='pending';const state=create([transport]);
 await waitFor(()=>typeof transport.release==='function');state.source.close();state.source.close();transport.release();await tick();
 assert.equal(transport.closed,1);assert.equal(transport.subscribed.length,0);assert.deepEqual(state.states,['connecting']);assert.equal(state.source.joinChat(1),false);
});

test('unacknowledged message overflow discards the failed attempt and its late acknowledgment',async()=>{
 const transport=new Transport();let acknowledge;transport.subscribe=async()=>{await new Promise(resolve=>{acknowledge=resolve;});};const state=create([transport]);
 try{
  await waitFor(()=>typeof acknowledge==='function');for(let i=0;i<17;i++)transport.message('ws:user:42',JSON.stringify({type:'notification_created',data:{id:i},timestamp:1}));
  assert.equal(state.states.at(-1),'unavailable');assert.equal(transport.closed,1);acknowledge();await tick();assert.deepEqual(state.messages,[]);assert(!state.states.includes('connected'));
 }finally{state.source.close();}
});

test('chat membership is bounded, reconciled and immediately filters departed channels',async()=>{
 const transport=new Transport(),state=create([transport]);
 try{
  await waitFor(()=>state.states.at(-1)==='connected');
  for(let id=1;id<=64;id++)assert.equal(state.source.joinChat(id),true);
  assert.equal(state.source.joinChat(1),true);for(const id of [65,0,-1,0.5,9007199254740992,'7'])assert.equal(state.source.joinChat(id),false);
  await waitFor(()=>new Set(transport.subscribed.flat()).size===68&&state.states.at(-1)==='connected');
  state.source.leaveChat(7);
  const raw=JSON.stringify({type:'chat_message',room:'chat:channel:7',data:{channel_id:7},timestamp:1});
  transport.message('ws:chat:channel:7',raw);assert.equal(state.messages.length,0);
  await waitFor(()=>transport.unsubscribed.flat().includes('ws:chat:channel:7'));assert.equal(state.source.joinChat(65),true);
 }finally{state.source.close();}
});

test('a stalled remote connect expires without relying on hidden transport retries',async()=>{
 const transport=new Transport();transport.mode='pending';const state=create([transport]);
 try{await waitFor(()=>state.states.at(-1)==='unavailable');assert.equal(transport.closed,1);assert.equal(transport.connects,1);}
 finally{state.source.close();}
});

test('invalid ownership and throwing callbacks do not leak transports',async()=>{
 let created=0;
 for(const userId of [0,-1,0.1,9007199254740992,'42'])assert.throws(()=>api.createRealtimeSubscription({userId,serverId:'local',createTransport:()=>{created++;return new Transport();},onState:()=>{},onMessage:()=>{}}));
 assert.equal(created,0);
 const transport=new Transport();const source=api.createRealtimeSubscription({userId:42,serverId:'local',createTransport:()=>transport,onState:()=>{},onMessage:()=>{throw Error('private-callback-detail');}});
 try{await waitFor(()=>transport.subscribed.length>0);transport.message('ws:user:42',JSON.stringify({type:'notification_created',data:{},timestamp:1}));assert.equal(transport.closed,1);}
 finally{source.close();}
});

test('factory failures are recoverable and a failed initial state callback never starts I/O',async()=>{
 let attempts=0;const states=[];const transport=new Transport();
 const source=api.createRealtimeSubscription({userId:42,serverId:'local',createTransport:()=>{if(++attempts===1)throw Error('private-config-detail');return transport;},onState:value=>states.push(value),onMessage:()=>{}});
 try{await waitFor(()=>states.at(-1)==='unavailable');await waitFor(()=>states.at(-1)==='connected');assert.equal(attempts,2);}
 finally{source.close();}
 let created=0;
 const failed=api.createRealtimeSubscription({userId:42,serverId:'local',createTransport:()=>{created++;return new Transport();},onState:()=>{throw Error('private-callback-detail');},onMessage:()=>{}});
 await tick();assert.equal(created,0);failed.close();
});
