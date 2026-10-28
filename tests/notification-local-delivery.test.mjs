import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createRequire} from 'node:module';
import {fileURLToPath,pathToFileURL} from 'node:url';
import path from 'node:path';
import {build} from 'esbuild';
console.log = () => {};
const root=fileURLToPath(new URL('../',import.meta.url));
const require=createRequire(import.meta.url);
const stubs={
  '#imports':'export const useRuntimeConfig=()=>({});',
  '~/server/storage':'export const normalizeAvatarPublicUrl=value=>value; export const normalizeNullableStoragePublicUrl=value=>value; export const normalizeStoragePublicUrl=value=>value;',
  '~/server/utils/redis':'export const REDIS_CHANNELS={USER_MESSAGE:"ws:user:"}; export const publishMessage=async(channel,message)=>globalThis.__localNotification.push({channel,message});',
  './api-cache':'export const readApiResponseCache=async()=>({status:"disabled"}); export const writeApiResponseCache=async()=>{}; export const invalidateApiResponseCache=async()=>{}; export const shouldInvalidateApiResponseCache=()=>false;',
  './logging':'export const getRequestLogContext=()=>null; export const logError=()=>{}; export const logInfo=()=>{}; export const serializeLogError=()=>({});',
  oracledb:'export default {OUT_FORMAT_OBJECT:4002};'
};
const bundle=await build({stdin:{contents:`export {v2PublishNotificationEvent} from './server/services/v2/notifications'; export {sessionManager} from './server/utils/wsSession';`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'local-notification-stubs',setup(builder){
  builder.onResolve({filter:/.*/},args=>{if(Object.hasOwn(stubs,args.path))return {path:args.path,namespace:'stub'};if(args.path.startsWith('~/'))return {path:path.join(root,`${args.path.slice(2)}.ts`)};if(args.path.startsWith('node:'))return {path:args.path,external:true};if(!args.path.startsWith('.')&&!path.isAbsolute(args.path))return {path:pathToFileURL(require.resolve(args.path)).href,external:true};});
  builder.onLoad({filter:/.*/,namespace:'stub'},args=>({contents:stubs[args.path],loader:'js'}));
}}]});
const subject=await import(`data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].text).toString('base64')}`);

test('local notification publication checks sessions before delivery and still publishes to Redis',async()=>{
  globalThis.__localNotification=[];
  const peer={messages:[],closed:0,send(value){this.messages.push(JSON.parse(value));},close(){this.closed++;}};
  let active=true;
  subject.sessionManager.addSession('local-session',peer,{userId:42,sessionId:'auth',jti:'jti',type:'access'},async()=>active);
  try {
    await subject.v2PublishNotificationEvent({},42,'notification_created',{id:7});
    assert.equal(peer.messages.length,1);
    assert.equal(globalThis.__localNotification.length,1);
    active=false;
    await subject.v2PublishNotificationEvent({},42,'notification_created',{id:8});
    assert.equal(peer.messages.length,1);
    assert.equal(peer.closed,1);
    assert.equal(globalThis.__localNotification.length,2);
  } finally { subject.sessionManager.removeSession('local-session'); delete globalThis.__localNotification; }
});
