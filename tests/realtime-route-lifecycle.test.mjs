import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createServer} from 'node:http';
import {once} from 'node:events';
import {readFileSync} from 'node:fs';
import WebSocket from 'ws';
import nodeAdapter from 'crossws/adapters/node';
import {loadRealtimeRoute,routeState,fakePeer,waitFor} from './helpers/realtime-route.mjs';
console.log=()=>{};
const subject=await loadRealtimeRoute();
const {channelIdCases}=JSON.parse(readFileSync(new URL('../specifications/scenarios/chat-websocket.json', import.meta.url), 'utf8'));
test('unauthenticated upgrade is rejected before any notification-capable socket is created',async()=>{
 globalThis.__wsRoute=routeState();
 try{
  const response=await subject.handler.upgrade({url:'http://api.test/_ws',headers:new Headers(),context:{}});
  assert(response instanceof Response,'unauthenticated upgrade must return an HTTP error');
  assert.equal(response.status,401);assert.equal((await response.json()).code,40101);assert.equal(globalThis.__wsRoute.transports.length,0);
 }finally{delete globalThis.__wsRoute;}
});
test('local presence remains available until the account is disabled',async()=>{
 globalThis.__wsRoute=routeState({redisOffline:true});const peer=fakePeer();
 try{
  await subject.handler.open(peer);assert.equal(peer.closed,0);
  await waitFor(()=>peer.messages.some(event=>event.data?.remote_events==='unavailable'));
  const presence={type:'presence_update',data:{user_id:9,online_status:'hidden',last_seen_at:null,server_id:subject.WS_SERVER_ID},timestamp:1};
  await subject.sendWsToAll(presence);assert.deepEqual(peer.messages.at(-1),presence);
  globalThis.__wsRoute.accountDisabled=true;await subject.sendWsToAll(presence);
  assert.equal(peer.closed,1);assert.equal(subject.sessionManager.getUserSessionCount(42),0);
  const rejected=await subject.handler.upgrade({url:'http://api.test/_ws?token=valid',headers:new Headers(),context:{}});
  assert.equal(rejected.status,401);
 }finally{if(peer.sessionId)subject.sessionManager.removeSession(peer.sessionId);delete globalThis.__wsRoute;}
});

test('upgrade fails closed for an unverified session and reports exhausted capacity',async()=>{
 const state=routeState({authError:new Error('synthetic-private-driver')});
 globalThis.__wsRoute=state;
 const request={url:'http://api.test/_ws?token=valid',headers:new Headers(),context:{}};
 const sessions=[];
 try{
  const rejected=await subject.handler.upgrade(request);
  assert.equal(rejected.status,401);
  assert.deepEqual(await rejected.json(),{code:40101,message:'Token无效或已过期',data:null,meta:null});
  delete state.authError;
  for(let i=0;i<1024;i++){
   const id='capacity-'+i;
   assert(subject.sessionManager.addSession(id,fakePeer(),{userId:42,type:'access'},async()=>true));
   sessions.push(id);
  }
  const full=await subject.handler.upgrade(request);
  assert.equal(full.status,503);
  assert.deepEqual(await full.json(),{code:50301,message:'服务暂不可用，请稍后重试。',data:null,meta:null});
  assert.equal(state.transports.length,0);
  subject.sessionManager.removeSession(sessions.pop());
  assert.equal(await subject.handler.upgrade(request),undefined);
 }finally{
  for(const id of sessions)subject.sessionManager.removeSession(id);
  delete globalThis.__wsRoute;
 }
});

test('actual Node WebSocket upgrade carries degraded status, local presence and revocation',async()=>{
 globalThis.__wsRoute=routeState({redisOffline:true});const adapter=nodeAdapter({hooks:subject.handler});const server=createServer();
 server.on('upgrade',(request,socket,head)=>{void adapter.handleUpgrade(request,socket,head);});
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));let socket;
 try{
  const received=[];socket=new WebSocket('ws://127.0.0.1:'+server.address().port+'/_ws?token=valid');socket.on('message',raw=>received.push(JSON.parse(raw.toString())));
  await once(socket,'open');await waitFor(()=>received.some(event=>event.data?.remote_events==='unavailable'));
  assert.equal(received[0].data.message,'WebSocket connected');
  const presence={type:'presence_update',data:{user_id:9,online_status:'hidden',last_seen_at:null,server_id:subject.WS_SERVER_ID},timestamp:1};
  await subject.sendWsToAll(presence);await waitFor(()=>received.some(event=>event.type==='presence_update'));
  const closed=once(socket,'close');globalThis.__wsRoute.active=false;await subject.sendWsToAll(presence);await closed;
  assert.equal(received.filter(event=>event.type==='presence_update').length,1);assert.equal(subject.sessionManager.getUserSessionCount(42),0);
  assert.equal(globalThis.__wsRoute.transports[0].closed,1);
 }finally{
  socket?.terminate();adapter.closeAll(1001,'',true);await new Promise(resolve=>server.close(resolve));delete globalThis.__wsRoute;
 }
});

test('close during initial authentication cannot create a session or remote transport',async()=>{
 let release;globalThis.__wsRoute=routeState({authGate:new Promise(resolve=>{release=resolve;})});const peer=fakePeer();
 try{
  const opening=subject.handler.open(peer);await new Promise(resolve=>setImmediate(resolve));await subject.handler.close(peer);release();await opening;
  assert.equal(peer.messages.length,0);assert.equal(globalThis.__wsRoute.transports.length,0);assert.equal(subject.sessionManager.getUserSessionCount(42),0);
 }finally{release();if(peer.sessionId)subject.sessionManager.removeSession(peer.sessionId);delete globalThis.__wsRoute;}
});

test('late chat authorization cannot rejoin a closed socket',async()=>{
 globalThis.__wsRoute=routeState();const peer=fakePeer();let release;
 try{
  await subject.handler.open(peer);await waitFor(()=>peer.messages.some(event=>event.data?.remote_events==='connected'));
  globalThis.__wsRoute.chatGate=new Promise(resolve=>{release=resolve;});
  const joining=subject.handler.message(peer,{text:()=>JSON.stringify({type:'chat_join_channel',data:{channelId:7}})});
  await new Promise(resolve=>setImmediate(resolve));await subject.handler.close(peer);const count=peer.messages.length;release();await joining;
  assert.equal(peer.messages.length,count);assert.equal(subject.sessionManager.getUserSessionCount(42),0);assert(!globalThis.__wsRoute.subscriptions.has('ws:chat:channel:7'));
 }finally{release?.();if(peer.sessionId)subject.sessionManager.removeSession(peer.sessionId);delete globalThis.__wsRoute;}
});

test('leave sent after a pending join takes effect in wire order', async () => {
 const state=routeState();globalThis.__wsRoute=state;
 const peer=fakePeer();
 let release;
 try {
  await subject.handler.open(peer);
  state.chatGate=new Promise(resolve=>{release=resolve;});
  const command=type=>subject.handler.message(peer,{text:()=>JSON.stringify({type,data:{channelId:7}})});
  const joining=command('chat_join_channel');
  await new Promise(resolve=>setImmediate(resolve));
  const leaving=command('chat_leave_channel');
  await new Promise(resolve=>setImmediate(resolve));
  release();
  await Promise.all([joining,leaving]);
  assert.equal(subject.sessionManager.getSession(peer.sessionId).joinedRooms.size,0);
 } finally {
  release?.();
  await subject.handler.close(peer);
  delete globalThis.__wsRoute;
 }
});

test('an overflowing inbound queue closes the socket and cancels its pending join', async () => {
 const state=routeState();globalThis.__wsRoute=state;
 const peer=fakePeer();
 let release;
 try {
  await subject.handler.open(peer);
  state.chatGate=new Promise(resolve=>{release=resolve;});
  const joining=subject.handler.message(peer,{text:()=>JSON.stringify({type:'chat_join_channel',data:{channelId:7}})});
  await new Promise(resolve=>setImmediate(resolve));
  const pings=Array.from({length:16},()=>subject.handler.message(peer,{text:()=>'{"type":"ping"}'}));
  assert.equal(peer.closed,1);
  assert.equal(subject.sessionManager.getUserSessionCount(42),0);
  release();
  await Promise.all([joining,...pings]);
  assert(!state.subscriptions.has('ws:chat:channel:7'));
  assert(!peer.messages.some(event=>event.type==='pong'));
 } finally {
  release?.();
  await subject.handler.close(peer);
  delete globalThis.__wsRoute;
 }
});

test('chat permissions, local delivery, channel limits and leaving remain effective',async()=>{
 globalThis.__wsRoute=routeState({chatAccess:false});const peer=fakePeer();
 const join=channelId=>subject.handler.message(peer,{text:()=>JSON.stringify({type:'chat_join_channel',data:{channelId}})});
 try{
  await subject.handler.open(peer);await waitFor(()=>peer.messages.some(event=>event.data?.remote_events==='connected'));
  await join(7);assert.equal(subject.sessionManager.getSession(peer.sessionId).joinedRooms.size,0);assert.equal(peer.messages.at(-1).type,'error');
  globalThis.__wsRoute.chatAccess=true;
  for (const vector of channelIdCases) {
   await join(vector.input);
   if (vector.channelId === null) {
    assert.equal(peer.messages.at(-1).type,'error');
   } else {
    assert(subject.sessionManager.getSession(peer.sessionId).joinedRooms.has(`chat:channel:${vector.channelId}`));
    await waitFor(()=>globalThis.__wsRoute.subscriptions.has(`ws:chat:channel:${vector.channelId}`));
    await subject.handler.message(peer,{text:()=>JSON.stringify({type:'chat_leave_channel',data:{channelId:vector.channelId}})});
    await waitFor(()=>!globalThis.__wsRoute.subscriptions.has(`ws:chat:channel:${vector.channelId}`));
   }
   assert.equal(subject.sessionManager.getSession(peer.sessionId).joinedRooms.size,0);
  }
  peer.messages.length=0;
  await join(7);await waitFor(()=>globalThis.__wsRoute.subscriptions.has('ws:chat:channel:7'));
  await waitFor(()=>peer.messages.some(value=>value.data?.code==='chat_channel_ready'&&value.data.channel_id===7));
  const event={type:'chat_message',room:'chat:channel:7',data:{channel_id:7,server_id:subject.WS_SERVER_ID},timestamp:1};
  await subject.sendWsToRoom('chat:channel:7',event);globalThis.__wsRoute.subscriptions.get('ws:chat:channel:7')(event);await new Promise(resolve=>setImmediate(resolve));
  assert.equal(peer.messages.filter(value=>value.type==='chat_message').length,1);
  const readyCount=()=>peer.messages.filter(value=>value.data?.code==='chat_channel_ready'&&value.data.channel_id===7).length;
  globalThis.__wsRoute.subscriptions.get('ws:system')({type:'system_notification',data:{code:'chat_channel_ready',channel_id:7,room:'chat:channel:7'},timestamp:1});
  assert.equal(readyCount(),1);
  globalThis.__wsRoute.transports[0].lost();
  await waitFor(()=>readyCount()===2);
  await subject.handler.message(peer,{text:()=>JSON.stringify({type:'chat_leave_channel',data:{channelId:7}})});
  await waitFor(()=>!globalThis.__wsRoute.subscriptions.has('ws:chat:channel:7'));
  for(let id=1;id<=64;id++)await join(id);await join(65);assert.equal(subject.sessionManager.getSession(peer.sessionId).joinedRooms.size,64);assert.equal(peer.messages.at(-1).type,'error');
 }finally{if(peer.sessionId)subject.sessionManager.removeSession(peer.sessionId);delete globalThis.__wsRoute;}
});
