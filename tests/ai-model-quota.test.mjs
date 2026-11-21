import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtempSync, readFileSync, rmdirSync } from 'node:fs';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';
import Redis from 'ioredis';
import ts from 'typescript';
import vm from 'node:vm';

const read = path => readFileSync(new URL(path, import.meta.url), 'utf8');
const contract = JSON.parse(read('../specifications/requirements/ai-model-quota.json'));
const { outputText } = ts.transpileModule(read('../server/utils/ai-model-quota.ts'), {
  compilerOptions: {module:ts.ModuleKind.CommonJS, target:ts.ScriptTarget.ES2022, esModuleInterop:true},
});
const exports = {};
vm.runInNewContext(outputText,{
  exports,
  require: name => name.endsWith('ai-model-quota.json') ? contract : {},
  Number, Error, process,
});
const { reserveAiModelQuota } = exports;

test('reserve sends numeric user and cost with the shared defaults, and rejects invalid storage and config', async () => {
  const redis={eval:async (script,keys,actor,service,cost,actorLimit,serviceLimit,window,max)=>{
    assert.equal(script,contract.lua);
    assert.deepEqual([keys,actor,service,cost,actorLimit,serviceLimit,window,max],[
      2,`${contract.keyPrefix}:actor:42`,`${contract.keyPrefix}:service`,2,20,120,60000,100000,
    ]);
    return 5;
  }};
  assert.equal(await reserveAiModelQuota(redis,42,2,{}),5);
  await assert.rejects(reserveAiModelQuota(undefined,42,2,{}),/unavailable/);
  await assert.rejects(reserveAiModelQuota({eval:async()=>61},42,2,{}),/unavailable/);
  let contacted=false;
  await assert.rejects(reserveAiModelQuota({eval:async()=>{contacted=true;return 0;}},42,2,{
    AI_QUOTA_ACTOR_PER_MINUTE:'02',
  }), /unavailable/);
  assert.equal(contacted,false);
});

const binary=process.env.NEKO_AI_TEST_REDIS_BIN;
test('isolated Redis admits only the allowed group cost and preserves both counters on rejection', {
  skip:!binary,timeout:10000,
}, async t=>{
  const probe=createServer().listen(0,'127.0.0.1');
  await once(probe,'listening');
  const {port}=probe.address();
  await new Promise(resolve=>probe.close(resolve));
  const dir=mkdtempSync(join(tmpdir(),'ai-quota-test-'));
  const child=spawn(binary,['--bind','127.0.0.1','--port',String(port),'--save','','--appendonly','no','--dir',dir],
    {windowsHide:true,stdio:['ignore','pipe','pipe']});
  let output='';
  for(const stream of [child.stdout,child.stderr]) stream.on('data',chunk=>{output=(output+chunk).slice(-2000);});
  const gone=new Promise(resolve=>{
    child.once('exit',resolve);
    child.once('error',resolve);
  });
  const redis=new Redis({host:'127.0.0.1',port,lazyConnect:true,connectTimeout:250,retryStrategy:()=>null});
  redis.on('error',()=>{});
  t.after(async()=>{
    redis.disconnect();
    if(child.pid&&child.exitCode===null)child.kill();
    await gone;
    rmdirSync(dir);
  });
  for(let attempt=0; ;attempt++){
    try {await redis.connect();break;}
    catch(error) {
      if(attempt>=15||child.exitCode!==null)throw new Error(output||String(error));
      await delay(100);
    }
  }
  assert.equal(Number((await redis.info('server')).match(/^process_id:(\d+)/m)?.[1]),child.pid);

  const actorKey=id=>`${contract.keyPrefix}:actor:${id}`;
  const serviceKey=`${contract.keyPrefix}:service`;
  const settings={AI_QUOTA_ACTOR_PER_MINUTE:'6',AI_QUOTA_SERVICE_PER_MINUTE:'8'};
  const reserve=(id,cost)=>reserveAiModelQuota(redis,id,cost,settings);
  const burst=await Promise.all(Array.from({length:16},()=>reserve(41,2)));
  assert.equal(burst.filter(retry=>retry===0).length,3);
  assert(burst.filter(Boolean).every(retry=>retry>=1&&retry<=60));
  assert.deepEqual(await redis.mget(actorKey(41),serviceKey),['6','6']);
  assert.equal(await reserve(42,2),0);
  assert((await reserve(43,1))>0);
  assert.deepEqual(await redis.mget(actorKey(43),serviceKey),[null,'8']);

  await redis.pexpire(actorKey(41),1);
  await delay(20);
  assert((await reserve(41,1))>0);
  assert.deepEqual(await redis.mget(actorKey(41),serviceKey),[null,'8']);
  await redis.set(serviceKey,'8');
  await assert.rejects(reserve(44,1),/unavailable/);
  assert.equal(await redis.get(actorKey(44)),null);
});
