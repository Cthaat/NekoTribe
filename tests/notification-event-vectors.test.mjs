// Compare the existing Nuxt event envelope with the native implementations.
// Redis, WebSocket and database boundaries are isolated; no real service starts.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {fileURLToPath,pathToFileURL} from 'node:url';
import path from 'node:path';
import {build} from 'esbuild';

const root=fileURLToPath(new URL('../',import.meta.url));
const require=createRequire(import.meta.url);
const stubs={
  '#imports':'export const useRuntimeConfig = () => ({});',
  '~/server/storage':'export const normalizeAvatarPublicUrl = value => value; export const normalizeNullableStoragePublicUrl = value => value; export const normalizeStoragePublicUrl = value => value;',
  '~/server/utils/redis':'export const REDIS_CHANNELS={USER_MESSAGE:"ws:user:"}; export const publishMessage=async(channel,message)=>globalThis.__nekoNotificationEvents.push({channel,message});',
  '~/server/utils/wsSession':'export const WS_SERVER_ID="test-instance"; export const sendWsToUser=(user,message)=>globalThis.__nekoNotificationEvents.push({user,message});',
  './api-cache':'export const readApiResponseCache=async()=>({status:"disabled"}); export const writeApiResponseCache=async()=>{}; export const invalidateApiResponseCache=async()=>{}; export const shouldInvalidateApiResponseCache=()=>false;',
  './logging':'export const getRequestLogContext=()=>null; export const logError=()=>{}; export const logInfo=()=>{}; export const serializeLogError=()=>({});',
  oracledb:'export default {OUT_FORMAT_OBJECT:4002};'
};
const result=await build({stdin:{contents:`export {v2PublishNotificationEvent} from './server/services/v2/notifications';`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'isolated',setup(builder){
  builder.onResolve({filter:/.*/},args=>{if(Object.hasOwn(stubs,args.path))return {path:args.path,namespace:'stub'};if(args.path.startsWith('~/'))return {path:path.join(root,`${args.path.slice(2)}.ts`)};if(args.path.startsWith('node:'))return {path:args.path,external:true};if(!args.path.startsWith('.')&&!path.isAbsolute(args.path))return {path:pathToFileURL(require.resolve(args.path)).href,external:true};});
  builder.onLoad({filter:/.*/,namespace:'stub'},args=>({contents:stubs[args.path],loader:'js'}));
}}]});
const {v2PublishNotificationEvent}=await import(`data:text/javascript;base64,${Buffer.from(result.outputFiles[0].text).toString('base64')}`);
const vectors=JSON.parse(readFileSync(path.join(root,'specifications/scenarios/notification-event-vectors.json'),'utf8'));
test('Nuxt emits shared notification events to local user and Redis channel',async()=>{
  const originalNow=Date.now;globalThis.__nekoNotificationEvents=[];
  try {for(const vector of vectors.cases.filter(item=>item.valid)){
    globalThis.__nekoNotificationEvents.length=0;Date.now=()=>vector.timestamp;
    await v2PublishNotificationEvent({},vector.user_id,vector.type,vector.data);
    const expected={type:vector.type,data:{...vector.data,server_id:vector.server_id},timestamp:vector.timestamp};
    assert.deepEqual(globalThis.__nekoNotificationEvents,[{user:vector.user_id,message:expected},{channel:`ws:user:${vector.user_id}`,message:expected}],vector.id);
  }} finally {Date.now=originalNow;delete globalThis.__nekoNotificationEvents;}
});
