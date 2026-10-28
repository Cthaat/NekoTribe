import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createRequire} from 'node:module';
import {fileURLToPath,pathToFileURL} from 'node:url';
import path from 'node:path';
import {build} from 'esbuild';
const root=fileURLToPath(new URL('../',import.meta.url));const require=createRequire(import.meta.url);
const stubs={
 '~/server/utils/v2':`export const v2Auth=e=>e.auth;export const v2Body=async e=>e.body;export const v2Boolean=v=>typeof v==='boolean'?v:typeof v==='number'?v===1:typeof v==='string'?['1','true','yes'].includes(v.toLowerCase()):false;export const v2Execute=async(_c,sql,binds)=>{globalThis.__read.calls.push({sql,binds});if(globalThis.__read.failWrite)throw new Error('write');return globalThis.__read.changed};export const v2One=async(_c,sql,binds)=>{globalThis.__read.calls.push({sql,binds});if(globalThis.__read.failRead)throw new Error('read');return globalThis.__read.row};export const v2Number=v=>Number(v)||0;export const v2DateString=v=>v||null;export const v2NotFound=()=>{throw new Error('not found')};export const v2Ok=data=>({code:200,message:'success',data,meta:null});export const v2Count=()=>{};export const v2JsonValue=()=>{};export const v2NextId=()=>{};export const v2Null=()=>{};export const v2NumberArray=()=>{};export const v2Page=()=>{};export const v2PageMeta=()=>{};export const v2QueryString=()=>{};export const v2RequiredNumber=()=>{};export const v2Rows=()=>{};export const v2String=()=>'';`,
 '~/server/models/v2':'export const v2GetPublicUser=()=>{};export const v2MapNotification=()=>{};',
 '~/server/utils/wsSession':'export const WS_SERVER_ID="test-instance";export const sendWsNotificationToUser=async(user,message)=>globalThis.__read.events.push({user,message});',
 '~/server/utils/redis':'export const REDIS_CHANNELS={USER_MESSAGE:"ws:user:"};export const publishMessage=async(channel,message)=>globalThis.__read.events.push({channel,message});'
};
const bundle=await build({stdin:{contents:`export {v2SetNotificationReadStatus} from './server/services/v2/notifications';`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'read-service-stubs',setup(builder){
 builder.onResolve({filter:/.*/},args=>{if(Object.hasOwn(stubs,args.path))return {path:args.path,namespace:'stub'};if(args.path.startsWith('~/'))return {path:path.join(root,`${args.path.slice(2)}.ts`)};if(args.path.startsWith('node:'))return {path:args.path,external:true};if(!args.path.startsWith('.')&&!path.isAbsolute(args.path))return {path:pathToFileURL(require.resolve(args.path)).href,external:true};});
 builder.onLoad({filter:/.*/,namespace:'stub'},args=>({contents:stubs[args.path],loader:'js'}));
}}]});
const {v2SetNotificationReadStatus}=await import(`data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].text).toString('base64')}`);
test('owned notification status update and event use the authenticated user',async()=>{
 globalThis.__read={changed:1,row:{NOTIFICATION_ID:12,IS_READ:1,READ_AT:'2026-01-02T03:04:05.000Z'},calls:[],events:[]};
 try {
  const result=await v2SetNotificationReadStatus({auth:{userId:42},body:{is_read:true,user_id:99}}, {},12);
  assert.deepEqual(result.data,{notification_id:12,is_read:1,read_at:'2026-01-02T03:04:05.000Z'});
  assert.equal(globalThis.__read.calls.length,2);
  for(const call of globalThis.__read.calls){assert.match(call.sql,/user_id\s*=\s*:user_id/);assert.equal(call.binds.user_id,42);assert.equal(call.binds.notification_id,12);}
  assert.equal(globalThis.__read.events.length,2);assert.equal(globalThis.__read.events[0].user,42);assert.equal(globalThis.__read.events[0].message.type,'notification_read_status_updated');assert.equal(globalThis.__read.events[1].channel,'ws:user:42');
  globalThis.__read.changed=0;globalThis.__read.calls=[];globalThis.__read.events=[];
  await assert.rejects(v2SetNotificationReadStatus({auth:{userId:42},body:{is_read:false}}, {},12),/not found/);
  assert.equal(globalThis.__read.calls.length,1);assert.equal(globalThis.__read.events.length,0);
  globalThis.__read.changed=1;globalThis.__read.failRead=true;globalThis.__read.calls=[];
  await assert.rejects(v2SetNotificationReadStatus({auth:{userId:42},body:{is_read:true}}, {},12),/read/);
  assert.equal(globalThis.__read.calls.length,2);assert.equal(globalThis.__read.events.length,0);
 } finally {delete globalThis.__read;}
});
