import {fileURLToPath} from 'node:url';
import path from 'node:path';
import {build} from 'esbuild';

const root=fileURLToPath(new URL('../../',import.meta.url));
const stubs={
 '~/server/services/v2/auth':`export function v2VerifyAccessToken(token){const s=globalThis.__wsRoute;const userId=token==='valid'?42:/^user[0-9]+$/.test(token)?Number(token.slice(4)):0;return userId&&!s.expired?{userId,sessionId:'auth-'+userId,jti:'jti-'+userId,type:'access'}:null;}`,
 '~/server/services/v2/chat':`export async function v2CanAccessChatChannel(){const s=globalThis.__wsRoute;if(s.chatGate)await s.chatGate;return s.chatAccess!==false;}
 export async function v2CanDeliverDirectMessage(_connection,user,conversation,message,deleted){return globalThis.__wsRoute.directAccess?.(user,conversation,message,deleted)??false;}`,
 '~/server/services/v2/presence':`export async function v2PublishUserPresence(){const s=globalThis.__wsRoute;s.presenceCalls=(s.presenceCalls??0)+1;}export async function v2TouchAuthSession(){const s=globalThis.__wsRoute;s.touchCalls=(s.touchCalls??0)+1;}`,
 '~/server/utils/oracle':`export const getOracleConnection=async()=>({close:async()=>{},async execute(sql){const s=globalThis.__wsRoute;if(s.authGate)await s.authGate;if(s.authError)throw s.authError;if(!sql.includes("u.status = 'active'")||!sql.includes('u.is_active = 1'))throw Error('Missing account predicate');return {rowsAffected:s.active&&!s.accountDisabled?1:0};}});`,
 '~/server/utils/oracle-query-cache':'export const attachOracleQueryCacheWithSource=(_options,connection)=>connection;',
 // Legacy exports deliberately fail; the integrated route must use the owned transport.
 '~/server/utils/redis':`export const getRedisClient=()=>null;export const getRedisSubscriber=()=>null;export const subscribeToChannel=async()=>false;export const REDIS_CHANNELS={BROADCAST:'ws:broadcast',SYSTEM_NOTIFICATION:'ws:system',PRESENCE:'ws:presence',CHAT_CHANNEL:'ws:chat:channel:',USER_MESSAGE:'ws:user:'};`,
 '~/server/utils/realtime-redis':`
 export function createRedisRealtimeTransport(){
  const s=globalThis.__wsRoute;s.transports??=[];s.listenerSets??=new Map();const own=new Map();let closed=false,message;
  const transport={closed:0,
   async connect(received,lost){message=received;transport.lost=lost;if(s.redisOffline)throw Error('synthetic-private-driver');},
   async subscribe(channels){
    if(s.failUserSubscription&&channels.includes('ws:user:43'))throw Error('synthetic-private-driver');
    if(channels.includes(s.delayedChannel)){s.attempts=(s.attempts??0)+1;await new Promise(resolve=>{s.releases??=[];s.releases.push(resolve);});}
    if(closed)throw Error('closed transport');
    for(const channel of channels){if(own.has(channel))continue;const listener=value=>message(channel,typeof value==='string'?value:JSON.stringify(value));own.set(channel,listener);let listeners=s.listenerSets.get(channel);if(!listeners){listeners=new Set();s.listenerSets.set(channel,listeners);}listeners.add(listener);s.subscriptions.set(channel,value=>{for(const listener of s.listenerSets.get(channel)??[])listener(value);});}
   },
   async unsubscribe(channels){for(const channel of channels){const listener=own.get(channel);s.listenerSets.get(channel)?.delete(listener);own.delete(channel);if(s.listenerSets.get(channel)?.size===0){s.listenerSets.delete(channel);s.subscriptions.delete(channel);}}},
   close(){if(closed)return;closed=true;transport.closed++;void transport.unsubscribe([...own.keys()]);}
  };s.transports.push(transport);return transport;
 }
 `
};

export async function loadRealtimeRoute(){
 const result=await build({stdin:{contents:`export {default as handler} from './server/routes/_ws';export {sessionManager,sendWsToAll,sendWsToRoom,sendWsToUser,sendWsNotificationToUser,sendWsEventToSession,sendWsRawToSession,WS_SERVER_ID} from './server/utils/wsSession';`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'owned-realtime-route',setup(builder){
  builder.onResolve({filter:/.*/},args=>{if(Object.hasOwn(stubs,args.path))return{path:args.path,namespace:'stub'};if(args.path.startsWith('~/'))return{path:path.join(root,args.path.slice(2)+'.ts')};});
  builder.onLoad({filter:/.*/,namespace:'stub'},args=>({contents:stubs[args.path],loader:'js'}));
 }}]});
 globalThis.defineWebSocketHandler=value=>value;
 try{return await import('data:text/javascript;base64,'+Buffer.from(result.outputFiles[0].text).toString('base64'));}
 finally{delete globalThis.defineWebSocketHandler;}
}
export function routeState(options={}){return{subscriptions:new Map(),listenerSets:new Map(),transports:[],active:true,expired:false,...options};}
export function fakePeer(token='valid'){return{request:{url:'/_ws?token='+token,headers:{}},messages:[],wires:[],closed:0,send(raw){this.wires.push(raw);this.messages.push(JSON.parse(raw));},close(){this.closed++;}};}
export async function waitFor(predicate){const deadline=Date.now()+3500;while(!predicate()){if(Date.now()>deadline)throw Error('route condition timed out');await new Promise(resolve=>setTimeout(resolve,5));}}
