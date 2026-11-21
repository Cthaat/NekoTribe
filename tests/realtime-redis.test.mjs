import assert from 'node:assert/strict';
import {test} from 'node:test';
import {fileURLToPath} from 'node:url';
import {build} from 'esbuild';
const built=await build({entryPoints:[fileURLToPath(new URL('../server/utils/realtime-redis.ts',import.meta.url))],bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'isolated-realtime-redis',setup(builder){
 builder.onResolve({filter:/^ioredis$/},()=>({path:'client',namespace:'stub'}));
 builder.onResolve({filter:/^\.\/redis-config$/},()=>({path:'config',namespace:'stub'}));
 builder.onLoad({filter:/.*/,namespace:'stub'},({path})=>({loader:'js',contents:path==='config'?'export const resolveRedisOptions=()=>({host:"redis.test",port:6380,password:"synthetic-private-password",tls:{},db:2});':`
 import {EventEmitter} from 'node:events';
 export default class Redis extends EventEmitter {
  constructor(options){super();this.options=options;this.status='wait';this.closed=0;this.commands=[];globalThis.__realtimeAdapter.client=this;}
  async connect(){if(globalThis.__realtimeAdapter.mode==='connect-fail')throw Error('synthetic-private-password');this.status='ready';}
  async subscribe(...channels){this.commands.push(['subscribe',...channels]);if(globalThis.__realtimeAdapter.mode==='subscribe-fail')throw Error('synthetic-private-password');return channels.length;}
  async unsubscribe(...channels){this.commands.push(['unsubscribe',...channels]);return 0;}
  async ping(){this.commands.push(['ping']);if(globalThis.__realtimeAdapter.mode==='ping-fail')throw Error('synthetic-private-password');return 'PONG';}
  disconnect(){this.closed++;this.status='end';this.emit('close');}
 }`}));
}}]});
const api=await import('data:text/javascript;base64,'+Buffer.from(built.outputFiles[0].text).toString('base64'));

test('realtime Redis preserves deployment config and disables hidden connection/command replay',()=>{
 globalThis.__realtimeAdapter={};const transport=api.createRedisRealtimeTransport();
 try{
  const options=globalThis.__realtimeAdapter.client.options;
  assert.equal(options.host,'redis.test');assert.equal(options.port,6380);assert.equal(options.db,2);assert.deepEqual(options.tls,{});
  assert.equal(options.lazyConnect,true);assert.equal(options.enableOfflineQueue,false);assert.equal(options.maxRetriesPerRequest,0);
  assert.equal(options.autoResubscribe,false);assert.equal(options.autoResendUnfulfilledCommands,false);assert.equal(options.commandTimeout,1500);assert.equal(options.connectTimeout,1500);assert.equal(options.retryStrategy(1),null);
 }finally{transport.close();delete globalThis.__realtimeAdapter;}
});

test('realtime Redis delivers raw strings and detaches lifecycle handlers on idempotent close',async()=>{
 globalThis.__realtimeAdapter={};const transport=api.createRedisRealtimeTransport();const messages=[];let lost=0;
 try{
  await transport.connect((channel,raw)=>messages.push([channel,raw]),()=>lost++);
  await transport.subscribe(['ws:user:42','ws:presence']);await transport.unsubscribe(['ws:presence']);
  const client=globalThis.__realtimeAdapter.client;client.emit('message','ws:user:42','raw-json');assert.deepEqual(messages,[['ws:user:42','raw-json']]);
  client.emit('error',Error('synthetic-private-password'));assert.equal(lost,1);
  transport.close();transport.close();assert.equal(client.closed,1);assert.equal(client.listenerCount('message'),0);
  client.emit('message','ws:user:42','late');client.emit('close');client.emit('error',Error('synthetic-private-password'));
  assert.equal(messages.length,1);assert.equal(lost,1);await assert.rejects(transport.subscribe(['ws:user:42']));
 }finally{transport.close();delete globalThis.__realtimeAdapter;}
});

for(const mode of ['connect-fail','subscribe-fail'])test('realtime Redis hides driver details in '+mode,async()=>{
 globalThis.__realtimeAdapter={mode};const transport=api.createRedisRealtimeTransport();
 try{
  const operation=async()=>{await transport.connect(()=>{},()=>{});await transport.subscribe(['ws:user:42']);};
  await assert.rejects(operation(),error=>error.message==='Realtime subscription unavailable');
 }finally{transport.close();delete globalThis.__realtimeAdapter;}
});

test('heartbeat failure is visible and closing cancels the heartbeat',async t=>{
 t.mock.timers.enable({apis:['setInterval']});globalThis.__realtimeAdapter={mode:'ping-fail'};
 const transport=api.createRedisRealtimeTransport();let lost=0;
 try{
  await transport.connect(()=>{},()=>lost++);const client=globalThis.__realtimeAdapter.client;
  t.mock.timers.tick(30000);await Promise.resolve();await Promise.resolve();assert.equal(lost,1);
  transport.close();t.mock.timers.tick(60000);await Promise.resolve();assert.equal(client.commands.filter(command=>command[0]==='ping').length,1);
 }finally{transport.close();t.mock.timers.reset();delete globalThis.__realtimeAdapter;}
});
