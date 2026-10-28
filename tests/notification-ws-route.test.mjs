import assert from 'node:assert/strict';
import {test} from 'node:test';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import {build} from 'esbuild';
import {createServer} from 'node:http';
import {connect} from 'node:net';
import nodeAdapter from 'crossws/adapters/node';

console.log = () => {};

const root = fileURLToPath(new URL('../', import.meta.url));
const stubs = {
  '~/server/services/v2/auth': `export function v2VerifyAccessToken(token) { const userId=token==='valid'?42:/^user4[345]$/.test(token)?Number(token.slice(4)):null; return userId && !globalThis.__wsRoute.expired ? {userId, sessionId:'auth-'+userId, jti:'jti-'+userId, type:'access'} : null; }`,
  '~/server/services/v2/chat': 'export const v2CanAccessChatChannel=async()=>true;',
  '~/server/services/v2/presence': 'export const v2PublishUserPresence=async()=>{}; export const v2TouchAuthSession=async()=>{};',
  '~/server/utils/oracle': 'export const getOracleConnection=async()=>({close:async()=>{}});',
  '~/server/utils/oracle-query-cache': 'export const attachOracleQueryCacheWithSource=(_options, connection)=>connection;',
  '~/server/utils/redis': `export const REDIS_CHANNELS={BROADCAST:'broadcast', SYSTEM_NOTIFICATION:'system', PRESENCE:'presence', CHAT_CHANNEL:'chat:', USER_MESSAGE:'ws:user:'}; export const getRedisClient=()=>null; export const getRedisSubscriber=()=>globalThis.__wsRoute.redisOffline ? null : {status:'ready'}; export const subscribeToChannel=async(channel, callback)=>{const state=globalThis.__wsRoute;if(channel==='ws:user:43' && state.failUserSubscription)return false;if(channel===state.delayedChannel){state.attempts++;await new Promise(resolve=>{state.release=resolve;});}state.subscriptions.set(channel,callback);return true;};`,
  '~/server/utils/v2': 'export const v2One=async()=>globalThis.__wsRoute.active ? {SESSION_ID:"auth-42"} : null; export const v2Execute=async()=>{};'
};
const result = await build({stdin:{contents:`export {default as handler} from './server/routes/_ws'; export {sessionManager} from './server/utils/wsSession';`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'ws-route-stubs',setup(builder){
  builder.onResolve({filter:/.*/}, args => {
    if (Object.hasOwn(stubs,args.path)) return {path:args.path,namespace:'stub'};
    if (args.path.startsWith('~/')) return {path:path.join(root,`${args.path.slice(2)}.ts`)};
  });
  builder.onLoad({filter:/.*/,namespace:'stub'}, args => ({contents:stubs[args.path],loader:'js'}));
}}]});
globalThis.defineWebSocketHandler=value=>value;
let subject;
try { subject=await import(`data:text/javascript;base64,${Buffer.from(result.outputFiles[0].text).toString('base64')}`); }
finally { delete globalThis.defineWebSocketHandler; }

test('Redis notification delivery revalidates the active session', async () => {
  globalThis.__wsRoute={subscriptions:new Map(),active:true,expired:false};
  const peer={request:{url:'/_ws?token=valid',headers:{}},messages:[],closed:0,send(value){this.messages.push(JSON.parse(value));},close(){this.closed++;}};
  try {
    await subject.handler.open(peer);
    assert.equal(peer.messages[0].type,'system_notification');
    const deliver=globalThis.__wsRoute.subscriptions.get('ws:user:42');
    assert.equal(typeof deliver,'function');
    const event={type:'notification_created',data:{id:7,server_id:'other'},timestamp:100};
    deliver(event);
    await new Promise(resolve=>setImmediate(resolve));
    assert.deepEqual(peer.messages[1],event);
    globalThis.__wsRoute.active=false;
    deliver(event);
    await new Promise(resolve=>setImmediate(resolve));
    assert.equal(peer.messages.length,2);
    assert.equal(peer.closed,1);
  } finally {
    if (peer.sessionId) subject.sessionManager.removeSession(peer.sessionId);
    delete globalThis.__wsRoute;
  }
});

test('heartbeat refuses to respond after the session is revoked', async () => {
  globalThis.__wsRoute={subscriptions:new Map(),active:true,expired:false};
  const peer={request:{url:'/_ws?token=valid',headers:{}},messages:[],closed:0,send(value){this.messages.push(JSON.parse(value));},close(){this.closed++;}};
  const ping={text:()=>JSON.stringify({type:'ping'})};
  try {
    await subject.handler.open(peer);
    await subject.handler.message(peer,ping);
    assert.equal(peer.messages.at(-1).type,'pong');
    globalThis.__wsRoute.active=false;
    await subject.handler.message(peer,ping);
    assert.equal(peer.closed,1);
    assert.equal(peer.messages.filter(message=>message.type==='pong').length,1);
    const count = peer.messages.length;
    await subject.handler.message(peer,{text:()=>JSON.stringify({type:'chat_join_channel',data:{channelId:1}})});
    assert.equal(peer.messages.length,count);
  } finally {
    if (peer.sessionId) subject.sessionManager.removeSession(peer.sessionId);
    delete globalThis.__wsRoute;
  }
});

test('upgrade permits absent, same-origin or explicitly allowed origins and rejects other origins', async () => {
  const oldOrigins=process.env.CORS_ALLOWED_ORIGINS;
  const oldNuxtOrigins=process.env.NUXT_CORS_ALLOWED_ORIGINS;
  const oldLocal=process.env.NUXT_CORS_ALLOW_LOCALHOST_ORIGINS;
  process.env.CORS_ALLOWED_ORIGINS='https://allowed.example';
  delete process.env.NUXT_CORS_ALLOWED_ORIGINS;
  process.env.NUXT_CORS_ALLOW_LOCALHOST_ORIGINS='false';
  const request=(origin, extra={})=>({url:'http://api.example:3000/_ws',headers:new Headers({host:'api.example:3000',...(origin === null ? {} : {origin}),...extra}),context:{}});
  try {
    for (const origin of [null,'http://api.example:3000','https://allowed.example']) {
      assert.equal(await subject.handler.upgrade(request(origin)),undefined,String(origin));
    }
    for (const origin of ['', 'https://evil.example','null','http://api.example:3000/path','https://api.example:3000','http://api.example:3000, https://evil.example']) {
      const response=await subject.handler.upgrade(request(origin,{'x-forwarded-proto':'https'}));
      assert.equal(response.status,403,origin);
    }
  } finally {
    if(oldOrigins===undefined) delete process.env.CORS_ALLOWED_ORIGINS; else process.env.CORS_ALLOWED_ORIGINS=oldOrigins;
    if(oldNuxtOrigins===undefined) delete process.env.NUXT_CORS_ALLOWED_ORIGINS; else process.env.NUXT_CORS_ALLOWED_ORIGINS=oldNuxtOrigins;
    if(oldLocal===undefined) delete process.env.NUXT_CORS_ALLOW_LOCALHOST_ORIGINS; else process.env.NUXT_CORS_ALLOW_LOCALHOST_ORIGINS=oldLocal;
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

test('a failed user subscription does not create a notification session and later retry can succeed', async () => {
  globalThis.__wsRoute={subscriptions:new Map(),active:true,expired:false,failUserSubscription:true};
  const makePeer=()=>({request:{url:'/_ws?token=user43',headers:{}},messages:[],closed:0,send(value){this.messages.push(JSON.parse(value));},close(){this.closed++;}});
  const failed=makePeer(), retried=makePeer();
  try {
    await subject.handler.open(failed);
    assert.equal(failed.closed,1);
    assert.equal(subject.sessionManager.getUserSessionCount(43),0);
    assert.equal(failed.messages.some(item=>item.data?.message==='WebSocket connected'),false);
    globalThis.__wsRoute.failUserSubscription=false;
    await subject.handler.open(retried);
    assert.equal(retried.closed,0);
    assert.equal(subject.sessionManager.getUserSessionCount(43),1);
    assert.equal(retried.messages.at(-1).data.message,'WebSocket connected');
    globalThis.__wsRoute.redisOffline=true;
    const offline=makePeer();
    await subject.handler.open(offline);
    assert.equal(offline.closed,1);
    assert.equal(subject.sessionManager.getUserSessionCount(43),1);
  } finally {
    if(failed.sessionId) subject.sessionManager.removeSession(failed.sessionId);
    if(retried.sessionId) subject.sessionManager.removeSession(retried.sessionId);
    delete globalThis.__wsRoute;
  }
});

test('simultaneous connections share one pending user subscription', async () => {
  globalThis.__wsRoute={subscriptions:new Map(),active:true,expired:false,delayedChannel:'ws:user:44',attempts:0};
  const makePeer=()=>({request:{url:'/_ws?token=user44',headers:{}},messages:[],closed:0,send(value){this.messages.push(JSON.parse(value));},close(){this.closed++;}});
  const first=makePeer(), second=makePeer();
  try {
    const opening=Promise.all([subject.handler.open(first),subject.handler.open(second)]);
    await new Promise(resolve=>setImmediate(resolve));
    assert.equal(globalThis.__wsRoute.attempts,1);
    globalThis.__wsRoute.release();
    await opening;
    assert.equal(subject.sessionManager.getUserSessionCount(44),2);
  } finally {
    if(first.sessionId) subject.sessionManager.removeSession(first.sessionId);
    if(second.sessionId) subject.sessionManager.removeSession(second.sessionId);
    delete globalThis.__wsRoute;
  }
});

test('a socket closed while subscribing cannot leave an active session', async () => {
  globalThis.__wsRoute={subscriptions:new Map(),active:true,expired:false,delayedChannel:'ws:user:45',attempts:0};
  const peer={request:{url:'/_ws?token=user45',headers:{}},messages:[],closed:0,send(value){this.messages.push(JSON.parse(value));},close(){this.closed++;}};
  try {
    const opening=subject.handler.open(peer);
    await new Promise(resolve=>setImmediate(resolve));
    assert.equal(globalThis.__wsRoute.attempts,1);
    await subject.handler.close(peer);
    globalThis.__wsRoute.release();
    await opening;
    assert.equal(subject.sessionManager.getUserSessionCount(45),0);
    assert.equal(peer.messages.length,0);
  } finally { if(peer.sessionId) subject.sessionManager.removeSession(peer.sessionId); delete globalThis.__wsRoute; }
});
