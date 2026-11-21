import assert from 'node:assert/strict';
import {test} from 'node:test';
import {build} from 'esbuild';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../',import.meta.url));
const marker='synthetic-private-redis-detail';
const built=await build({
 stdin:{contents:"export {publishMessage} from './server/utils/redis';",resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',
 plugins:[{name:'isolated-redis',setup(builder){
  builder.onResolve({filter:/^ioredis$/},()=>({path:'ioredis',namespace:'stub'}));
  builder.onResolve({filter:/^\.\/redis-config$/},()=>({path:'config',namespace:'stub'}));
  builder.onLoad({filter:/.*/,namespace:'stub'},({path})=>({contents:path==='config'?'export const resolveRedisOptions=()=>({});':
   'import {EventEmitter} from "node:events";export default class Redis extends EventEmitter { constructor(options){super();const s=globalThis.__presenceRedis;s.options=options;this.status=s.mode==="ready-error"?"connecting":"ready";if(s.mode==="construct-error")throw Error(s.marker);if(s.mode==="ready-error")queueMicrotask(()=>this.emit("error",Error(s.marker)));}async publish(channel,message){const s=globalThis.__presenceRedis;s.calls++;if(s.mode==="publish-error")throw Error(s.marker);return 1;}}',loader:'js'}));
 }}]
});
const url='data:text/javascript;base64,'+Buffer.from(built.outputFiles[0].text).toString('base64');
for(const mode of ['construct-error','ready-error','publish-error','success'])test('presence Redis adapter safe logs '+mode,async()=>{
 const previous={log:console.log,error:console.error},logs=[];
 globalThis.__presenceRedis={mode,marker,calls:0};
 console.log=(...values)=>logs.push(values.map(String).join(' '));console.error=(...values)=>logs.push(values.map(String).join(' '));
 try{
  const api=await import(url+'#'+mode);
  await api.publishMessage('ws:presence',{type:'presence_update',data:{user_id:42,online_status:'hidden',last_seen_at:null,server_id:'test-instance',private:marker},timestamp:1});
  assert(!logs.join('\n').includes(marker),'driver or event payload leaked into publication logs');
  assert.equal(globalThis.__presenceRedis.options.commandTimeout,1500);
  assert.equal(globalThis.__presenceRedis.options.autoResendUnfulfilledCommands,false);
  assert.equal(globalThis.__presenceRedis.options.maxRetriesPerRequest,0);
  assert.equal(globalThis.__presenceRedis.calls,['success','publish-error'].includes(mode)?1:0);
 }finally{console.log=previous.log;console.error=previous.error;delete globalThis.__presenceRedis;}
});
