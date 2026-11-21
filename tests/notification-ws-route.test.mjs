import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createServer} from 'node:http';
import {connect} from 'node:net';
import nodeAdapter from 'crossws/adapters/node';
import {loadRealtimeRoute,routeState,fakePeer,waitFor} from './helpers/realtime-route.mjs';

console.log=()=>{};
const subject=await loadRealtimeRoute();
const tick=()=>new Promise(resolve=>setImmediate(resolve));
const hasState=(peer,state)=>peer.messages.some(event=>event.data?.code==='realtime_status'&&event.data.remote_events===state);

test('Redis notification delivery revalidates the active session',async()=>{
 globalThis.__wsRoute=routeState();const peer=fakePeer();
 try{
  await subject.handler.open(peer);await waitFor(()=>hasState(peer,'connected'));
  const deliver=globalThis.__wsRoute.subscriptions.get('ws:user:42');
  const event={type:'notification_created',data:{id:7,server_id:'other'},timestamp:100};
  deliver(event);await waitFor(()=>peer.messages.some(item=>item.type==='notification_created'));
  assert.deepEqual(peer.messages.at(-1),event);globalThis.__wsRoute.active=false;deliver(event);
  await waitFor(()=>peer.closed===1);assert.equal(peer.messages.filter(item=>item.type==='notification_created').length,1);
  assert.equal(globalThis.__wsRoute.transports[0].closed,1);
 }finally{if(peer.sessionId)subject.sessionManager.removeSession(peer.sessionId);delete globalThis.__wsRoute;}
});

test('local and Redis direct messages require current message access',async()=>{
 const checks=[];
 globalThis.__wsRoute=routeState({directAccess:(user,conversation,message,deleted)=>{
  checks.push([user,conversation,message,deleted]);return user===42 && conversation===12 && message===(deleted?10:9);
 }});
 const peer=fakePeer();
 const frame=message_id=>({type:'direct_message',data:{conversation_id:12,direct_message:{conversation_id:12,message_id}},timestamp:1});
 try {
  await subject.handler.open(peer);await waitFor(()=>hasState(peer,'connected'));
  await subject.sendWsToUser(42,frame(7));
  globalThis.__wsRoute.subscriptions.get('ws:user:42')(frame(8));
  globalThis.__wsRoute.subscriptions.get('ws:user:42')(frame(9));
  const deletion=message_id=>({type:'direct_message_deleted',data:{conversation_id:12,message_id},timestamp:1});
  globalThis.__wsRoute.subscriptions.get('ws:user:42')(deletion(9));
  globalThis.__wsRoute.subscriptions.get('ws:user:42')(deletion(10));
  await waitFor(()=>peer.messages.some(event=>event.type==='direct_message_deleted'));
  assert.deepEqual(checks,[[42,12,7,false],[42,12,8,false],[42,12,9,false],[42,12,9,true],[42,12,10,true]]);
  assert.deepEqual(peer.messages.filter(event=>event.type==='direct_message'),[frame(9)]);
  assert.deepEqual(peer.messages.filter(event=>event.type==='direct_message_deleted'),[deletion(10)]);
 } finally {if(peer.sessionId)subject.sessionManager.removeSession(peer.sessionId);delete globalThis.__wsRoute;}
});

test('heartbeat refuses to respond after the session is revoked',async()=>{
 globalThis.__wsRoute=routeState();const peer=fakePeer();const ping={text:()=>JSON.stringify({type:'ping'})};
 try{
  await subject.handler.open(peer);await waitFor(()=>hasState(peer,'connected'));
  await subject.handler.message(peer,ping);assert.equal(peer.messages.at(-1).type,'pong');
  globalThis.__wsRoute.active=false;await subject.handler.message(peer,ping);assert.equal(peer.closed,1);
  assert.equal(peer.messages.filter(item=>item.type==='pong').length,1);const count=peer.messages.length;
  await subject.handler.message(peer,{text:()=>JSON.stringify({type:'chat_join_channel',data:{channelId:1}})});
  assert.equal(peer.messages.length,count);
 }finally{if(peer.sessionId)subject.sessionManager.removeSession(peer.sessionId);delete globalThis.__wsRoute;}
});

test('upgrade permits absent, same-origin or explicitly allowed origins and rejects other origins', async () => {
  const oldOrigins=process.env.CORS_ALLOWED_ORIGINS;
  const oldNuxtOrigins=process.env.NUXT_CORS_ALLOWED_ORIGINS;
  const oldLocal=process.env.NUXT_CORS_ALLOW_LOCALHOST_ORIGINS;
  const oldBase=process.env.BASE_URL;
  process.env.CORS_ALLOWED_ORIGINS='https://allowed.example';
  delete process.env.NUXT_CORS_ALLOWED_ORIGINS;
  process.env.NUXT_CORS_ALLOW_LOCALHOST_ORIGINS='false';
  process.env.BASE_URL='https://neko.example:8443/';
  const request=(origin, extra={})=>({url:'http://api.example:3000/_ws?token=valid',headers:new Headers({host:'api.example:3000',...(origin === null ? {} : {origin}),...extra}),context:{}});
  globalThis.__wsRoute=routeState();
  try {
    for (const origin of [null,'http://api.example:3000','https://allowed.example','https://neko.example:8443']) {
      assert.equal(await subject.handler.upgrade(request(origin)),undefined,String(origin));
    }
    for (const origin of ['', 'https://evil.example','null','http://api.example:3000/path','https://api.example:3000','http://api.example:3000, https://evil.example','https://neko.example','https://neko.example:8443/']) {
      const response=await subject.handler.upgrade(request(origin,{'x-forwarded-proto':'https'}));
      assert.equal(response.status,403,origin);
    }
  } finally {
    if(oldOrigins===undefined) delete process.env.CORS_ALLOWED_ORIGINS; else process.env.CORS_ALLOWED_ORIGINS=oldOrigins;
    if(oldNuxtOrigins===undefined) delete process.env.NUXT_CORS_ALLOWED_ORIGINS; else process.env.NUXT_CORS_ALLOWED_ORIGINS=oldNuxtOrigins;
    if(oldLocal===undefined) delete process.env.NUXT_CORS_ALLOW_LOCALHOST_ORIGINS; else process.env.NUXT_CORS_ALLOW_LOCALHOST_ORIGINS=oldLocal;
    if(oldBase===undefined) delete process.env.BASE_URL; else process.env.BASE_URL=oldBase;
    delete globalThis.__wsRoute;
  }
});

test('Node WebSocket adapter rejects a hostile Origin before upgrading', async () => {
  const adapter=nodeAdapter({hooks:subject.handler});
  const server=createServer();
  server.on('upgrade',(request,socket,head)=>{ void adapter.handleUpgrade(request,socket,head); });
  await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});
  try {
    const port=server.address().port;
    const response=await new Promise((resolve,reject)=>{
      const socket=connect(port,'127.0.0.1');
      let received='';
      socket.setTimeout(3000,()=>socket.destroy(new Error('handshake timeout')));
      socket.on('connect',()=>socket.write(`GET /_ws HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nOrigin: https://hostile.example\r\n\r\n`));
      socket.on('data',chunk=>{received+=chunk.toString();});
      socket.on('end',()=>resolve(received));
      socket.on('error',reject);
    });
    assert.match(response,/^HTTP\/1\.1 403 /);
    assert.doesNotMatch(response,/101 Switching Protocols/);
  } finally { adapter.closeAll(1001,'',true); await new Promise(resolve=>server.close(resolve)); }
});

test('failed user subscriptions retain explicit local capability and recover without reopening the socket',async()=>{
 globalThis.__wsRoute=routeState({failUserSubscription:true});const peer=fakePeer('user43'),offline=fakePeer('user43');
 try{
  await subject.handler.open(peer);await waitFor(()=>hasState(peer,'unavailable'));
  assert.equal(peer.closed,0);assert.equal(subject.sessionManager.getUserSessionCount(43),1);
  globalThis.__wsRoute.failUserSubscription=false;await waitFor(()=>hasState(peer,'connected'));
  globalThis.__wsRoute.redisOffline=true;await subject.handler.open(offline);await waitFor(()=>hasState(offline,'unavailable'));
  assert.equal(offline.closed,0);assert.equal(subject.sessionManager.getUserSessionCount(43),2);
 }finally{for(const target of [peer,offline])if(target.sessionId)subject.sessionManager.removeSession(target.sessionId);delete globalThis.__wsRoute;}
});

test('simultaneous sockets own independent subscriptions and release only their own transport',async()=>{
 globalThis.__wsRoute=routeState({delayedChannel:'ws:user:44',attempts:0});const first=fakePeer('user44'),second=fakePeer('user44');
 try{
  await Promise.all([subject.handler.open(first),subject.handler.open(second)]);await waitFor(()=>globalThis.__wsRoute.attempts===2);
  assert.equal(subject.sessionManager.getUserSessionCount(44),2);
  const presence={type:'presence_update',data:{user_id:9,online_status:'hidden',last_seen_at:null,server_id:'peer'},timestamp:1};
  await subject.sendWsToAll(presence);assert.deepEqual(first.messages.at(-1),presence);assert.deepEqual(second.messages.at(-1),presence);
  await subject.handler.close(first);const count=first.messages.length;
  globalThis.__wsRoute.releases.splice(0).forEach(resolve=>resolve());await waitFor(()=>hasState(second,'connected'));await tick();
  assert.equal(first.messages.length,count);assert.equal(subject.sessionManager.getUserSessionCount(44),1);
  assert.equal(globalThis.__wsRoute.listenerSets.get('ws:user:44').size,1);
  assert.equal(globalThis.__wsRoute.transports[0].closed,1);assert.equal(globalThis.__wsRoute.transports[1].closed,0);
 }finally{for(const peer of [first,second])if(peer.sessionId)subject.sessionManager.removeSession(peer.sessionId);delete globalThis.__wsRoute;}
});

test('a socket closed during pending subscription cannot recover or leave a registered session',async()=>{
 globalThis.__wsRoute=routeState({delayedChannel:'ws:user:45',attempts:0});const peer=fakePeer('user45');
 try{
  await subject.handler.open(peer);await waitFor(()=>globalThis.__wsRoute.attempts===1);
  await subject.handler.close(peer);const count=peer.messages.length;
  globalThis.__wsRoute.releases.splice(0).forEach(resolve=>resolve());await tick();
  assert.equal(subject.sessionManager.getUserSessionCount(45),0);assert.equal(peer.messages.length,count);
  assert.equal(globalThis.__wsRoute.transports[0].closed,1);assert.equal(globalThis.__wsRoute.subscriptions.size,0);
 }finally{if(peer.sessionId)subject.sessionManager.removeSession(peer.sessionId);delete globalThis.__wsRoute;}
});
