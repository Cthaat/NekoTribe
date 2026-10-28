import assert from 'node:assert/strict';
import {test} from 'node:test';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import {build} from 'esbuild';

console.log = () => {};

const root = fileURLToPath(new URL('../', import.meta.url));
const stubs = {
  '~/server/services/v2/auth': `export function v2VerifyAccessToken(token) { return token === 'valid' && !globalThis.__wsRoute.expired ? {userId:42, sessionId:'auth-42', jti:'jti-42', type:'access'} : null; }`,
  '~/server/services/v2/chat': 'export const v2CanAccessChatChannel=async()=>true;',
  '~/server/services/v2/presence': 'export const v2PublishUserPresence=async()=>{}; export const v2TouchAuthSession=async()=>{};',
  '~/server/utils/oracle': 'export const getOracleConnection=async()=>({close:async()=>{}});',
  '~/server/utils/oracle-query-cache': 'export const attachOracleQueryCacheWithSource=(_options, connection)=>connection;',
  '~/server/utils/redis': `export const REDIS_CHANNELS={BROADCAST:'broadcast', SYSTEM_NOTIFICATION:'system', PRESENCE:'presence', CHAT_CHANNEL:'chat:', USER_MESSAGE:'ws:user:'}; export const getRedisClient=()=>null; export const subscribeToChannel=async(channel, callback)=>{globalThis.__wsRoute.subscriptions.set(channel, callback);return true;};`,
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
