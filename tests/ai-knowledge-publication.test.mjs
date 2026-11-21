import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtemp, readFile, rm, rmdir, writeFile } from 'node:fs/promises';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { parseProfile, profileFingerprint } from '../scripts/knowledge-index/config.mjs';
import { prune, publish, recover, rollbackTarget } from '../scripts/knowledge-index/lifecycle.mjs';
import { checkIndexReadiness, startIndexServer } from '../scripts/knowledge-index/server.mjs';
import { syncIndex } from '../scripts/knowledge-index/sync.mjs';
import { activateIndex, bootstrapIndex, switchIndex } from '../scripts/knowledge-index/bootstrap.mjs';
import { indexStore } from '../scripts/knowledge-index/qdrant.mjs';
import { indexProgress } from '../scripts/knowledge-index/progress.mjs';
import { readWatchStatus, writeWatchStatus } from '../scripts/knowledge-index/watch-status.mjs';

const vectors = JSON.parse(await readFile(new URL('../specifications/scenarios/ai-knowledge-index-publication.json',import.meta.url),'utf8'));

function profile(suffix) {
  return parseProfile({version:1,collection:`neko_knowledge_sync_${suffix.repeat(32)}`,adapter:'ollama',
    baseUrl:'http://models.example.test',model:'fixture/embed',modelRevision:'v1',dimensions:3,keyEnv:null});
}

async function files(t) {
  const folder = await mkdtemp(join(tmpdir(),'neko-index-publication-'));
  const active = join(folder,'active.json');
  const initial = join(folder,'initial.json');
  const ledger = `${active}.collections.json`;
  const journal = `${active}.publication.json`;
  const status = `${active}.sync-status.json`;
  t.after(async () => {
    await Promise.all([active,initial,ledger,journal,status].map(path => rm(path,{force:true})));
    await rmdir(folder);
  });
  return {active,initial,ledger,journal,status};
}

const save = (path,value) => writeFile(path,JSON.stringify(value));
const load = async path => JSON.parse(await readFile(path,'utf8'));
const previous = profile('a'), next = profile('b'), external = profile('c');
const oldLedger = {version:1,collections:[{profile:previous,retiredAt:null}]};
const newLedger = {version:1,collections:[{profile:previous,retiredAt:1700000000000},{profile:next,retiredAt:null}]};

test('retired index pruning preserves unverifiable collections while removing verified entries', async t => {
  const {active,ledger} = await files(t);
  const missing = profile('c'), mismatched = profile('d'), verified = profile('e'), absent = profile('f');
  await save(active,previous);
  const now = Date.now(), day = 86400000;
  const retired = [next,missing,mismatched,verified,absent].map((item,index) =>
    ({profile:item,retiredAt:now-(index+2)*day}));
  await save(ledger,{version:1,collections:[...oldLedger.collections,...retired]});
  const settings = {AI_INDEX_KEEP_RETIRED:'1',AI_INDEX_RETENTION_DAYS:'1',AI_INDEX_QDRANT_URL:'http://index.example.test'};
  const env = Object.fromEntries(Object.keys(settings).map(name => [name,process.env[name]]));
  Object.assign(process.env,settings);
  const previousFetch = globalThis.fetch;
  t.after(() => {
    globalThis.fetch = previousFetch;
    for (const [name,value] of Object.entries(env)) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
  });
  const deleted = [];
  globalThis.fetch = async (url,options) => {
    const [,collection,...parts] = new URL(url).pathname.slice(1).split('/');
    assert.notEqual(collection,previous.collection);
    assert.notEqual(collection,next.collection);
    const response = result => Response.json({status:'ok',result});
    if (parts[0] === 'exists') return response({exists:collection !== absent.collection});
    if (parts[0] === 'points') {
      if (collection === missing.collection) return new Response(null,{status:404});
      const owner = collection === verified.collection ? verified : previous;
      return response({id:parts[1],payload:{fingerprint:profileFingerprint(owner),points:12}});
    }
    assert.equal(options.method,'DELETE');
    assert.equal(collection,verified.collection);
    deleted.push(collection);
    return response(true);
  };
  const eligible = retired.slice(1).map(item => item.profile.collection);
  assert.deepEqual(await prune(active,false),{active:previous.collection,eligible,removed:[],skipped:[]});
  assert.deepEqual(await prune(active,true),{
    active:previous.collection,eligible,removed:[verified.collection,absent.collection],
    skipped:[{collection:missing.collection,code:'INDEX_MARKER_MISSING'},
      {collection:mismatched.collection,code:'INDEX_PROFILE_MISMATCH'}],
  });
  assert.deepEqual(deleted,[verified.collection]);
  assert.deepEqual((await load(ledger)).collections,[...oldLedger.collections,...retired.slice(0,3)]);
});

test('index progress limits repeated stages and omits private fields', () => {
  const messages = [];
  let time = 0;
  const report = indexProgress('switch',{write:text=>messages.push(JSON.parse(text)),now:()=>time});
  report({stage:'checking-model',endpoint:'private endpoint'});
  report({stage:'writing-points',points:0});
  time = 9999;
  report({stage:'writing-points',points:7});
  time = 10000;
  report({stage:'writing-points',sources:12,points:14,reused:7});
  report({stage:'verifying-collection',sources:12,points:14,reused:7,content:'private content'});
  assert.deepEqual(messages,[
    {type:'index-progress',mode:'switch',stage:'checking-model'},
    {type:'index-progress',mode:'switch',stage:'writing-points',points:0},
    {type:'index-progress',mode:'switch',stage:'writing-points',sources:12,points:14,reused:7},
    {type:'index-progress',mode:'switch',stage:'verifying-collection',sources:12,points:14,reused:7},
  ]);
});

test('build sends diagnostics to stderr and reserves stdout for the final result',async t => {
  const {initial} = await files(t);
  await save(initial,next);
  const cli = fileURLToPath(new URL('../scripts/knowledge-index/cli.mjs',import.meta.url));
  const run = promisify(execFile)(process.execPath,[cli,'build',initial],{
    env:{...process.env,AI_INDEX_ORACLE_USER:'',AI_INDEX_ORACLE_PASSWORD:'',AI_INDEX_ORACLE_CONNECT:''},
    timeout:5000,
  });
  await assert.rejects(run,error=>{
    const [progress,failure] = error.stderr.trim().split(/\r?\n/);
    assert.deepEqual(JSON.parse(progress),{type:'index-progress',mode:'build',stage:'checking-sources'});
    assert.equal(failure,'Knowledge index build failed: ORACLE_CONFIG_REQUIRED');
    assert.equal(error.stdout,'');
    assert.equal(error.code,1);
    return true;
  });
});

test('verify can inspect a candidate or the active profile without publishing',async t => {
  const {initial,active,ledger,journal} = await files(t);
  await save(initial,next);
  await save(active,previous);
  await save(ledger,oldLedger);
  const marker = {id:'00000000-0000-4000-8000-000000000000',vector:[1,0,0],
    payload:{points:0,fingerprint:profileFingerprint(next)}};
  const hook = `
    globalThis.fetch = async (url, {method}) => {
      if (method !== 'POST') throw Error('UNEXPECTED_REQUEST');
      switch (url) {
        case ${JSON.stringify(`${next.baseUrl}/api/embed`)}:
          return Response.json({model:${JSON.stringify(next.model)},embeddings:[[1,0,0]]});
        case ${JSON.stringify(`http://index.example.test/collections/${next.collection}/points`)}:
          return Response.json({status:'ok',result:[${JSON.stringify(marker)}]});
        case ${JSON.stringify(`http://index.example.test/collections/${next.collection}/points/count`)}:
          return Response.json({status:'ok',result:{count:1}});
        case ${JSON.stringify(`http://index.example.test/collections/${next.collection}/points/query`)}:
          return Response.json({status:'ok',result:{points:[]}});
        default: throw Error('UNEXPECTED_REQUEST');
      }
    };`;
  const cli = fileURLToPath(new URL('../scripts/knowledge-index/cli.mjs',import.meta.url));
  const verify = async (...args) => {
    const {stdout,stderr} = await promisify(execFile)(process.execPath,
      ['--import',`data:text/javascript,${encodeURIComponent(hook)}`,cli,'verify',...args],{
        env:{...process.env,AI_INDEX_ACTIVE_PROFILE:active,AI_INDEX_QDRANT_URL:'http://index.example.test'},timeout:5000,
      });
    assert.deepEqual(JSON.parse(stdout),{mode:'verify',collection:next.collection,points:0,verified:true});
    assert.deepEqual(JSON.parse(stderr),{type:'index-progress',mode:'verify',stage:'checking-candidate'});
  };
  await verify(initial);
  assert.deepEqual(await load(active),previous);
  await save(active,next);
  await verify();
  assert.deepEqual(await load(active),next);
  assert.deepEqual(await load(ledger),oldLedger);
  await assert.rejects(readFile(journal),{code:'ENOENT'});
});

test('stopping index writes cancels Qdrant requests and skips subsequent verification or marker writes', async t => {
  const priorUrl = process.env.AI_INDEX_QDRANT_URL;
  process.env.AI_INDEX_QDRANT_URL = 'http://index.example.test';
  t.after(() => {
    if (priorUrl === undefined) delete process.env.AI_INDEX_QDRANT_URL;
    else process.env.AI_INDEX_QDRANT_URL = priorUrl;
  });
  const store = indexStore(next);
  for (const [stage, operation] of [
    ['CREATE', signal => store.create(signal)],
    ['UPSERT', signal => store.upsert([],signal)],
    ['SEAL_COUNT', signal => store.seal(0,[1,0,0],'a'.repeat(64),signal)],
    ['VERIFY_MARKER', signal => store.verify([1,0,0],signal)],
  ]) {
    const controller = new AbortController();
    const pending = Promise.withResolvers();
    const calls = [];
    const mock = t.mock.method(globalThis,'fetch',(url,options) => {
      const path = new URL(url).pathname.replace(`/collections/${next.collection}`,'');
      calls.push([options.method,path]);
      if (path === '/exists') return Response.json({status:'ok',result:{exists:false}});
      pending.resolve(options.signal);
      return new Promise((_,reject) => options.signal.addEventListener('abort',() => reject(Error('transport aborted')),{once:true}));
    });
    try {
      const running = operation(controller.signal);
      const requestSignal = await pending.promise;
      assert.equal(requestSignal.aborted,false,stage);
      controller.abort(Error(stage));
      assert.equal(requestSignal.aborted,true,stage);
      await assert.rejects(running,error => error === controller.signal.reason);
      assert.deepEqual(calls,{
        CREATE:[['GET','/exists'],['PUT','']],
        UPSERT:[['PUT','/points']],
        SEAL_COUNT:[['POST','/points/count']],
        VERIFY_MARKER:[['POST','/points']],
      }[stage]);
    } finally {
      mock.mock.restore();
    }
  }
});

function bootstrapDependencies(t, {exists = false, sealed = false, count = 1, beforeProbe} = {}) {
  const priorUrl = process.env.AI_INDEX_QDRANT_URL;
  process.env.AI_INDEX_QDRANT_URL = 'http://index.example.test';
  t.after(() => {
    if (priorUrl === undefined) delete process.env.AI_INDEX_QDRANT_URL;
    else process.env.AI_INDEX_QDRANT_URL = priorUrl;
  });
  const calls = [];
  const marker = {
    id:'00000000-0000-4000-8000-000000000000',
    payload:{fingerprint:profileFingerprint(next),points:0},
    vector:[1,0,0],
  };
  t.mock.method(globalThis,'fetch',async (url) => {
    const {origin,pathname} = new URL(url);
    calls.push(pathname);
    if (origin === 'http://models.example.test') {
      assert.equal(pathname,'/api/embed');
      await beforeProbe?.();
      return Response.json({model:next.model,embeddings:[[1,0,0]]});
    }
    assert.equal(origin,'http://index.example.test');
    const route = pathname.replace(`/collections/${next.collection}`,'');
    const respond = result => Response.json({status:'ok',result});
    if (route === '/exists') return respond({exists});
    if (route === '/points') return respond(sealed ? [marker] : []);
    if (route === '/points/count') return respond({count});
    if (route === '/points/query') return respond({points:[]});
    if (route === `/points/${marker.id}` && sealed) return respond(marker);
    throw Error(`Unexpected fixture request: ${pathname}`);
  });
  return {calls, finishBuild() {exists = sealed = true;}};
}

test('bootstrap builds once and rechecks an existing activation without reading the seed',async t => {
  const {active,initial} = await files(t);
  const deps = bootstrapDependencies(t);
  await save(initial,next);
  let builds = 0;
  const loadBuilder = async () => ({buildIndex:async profile => {
    assert.deepEqual(profile,next);
    builds++;
    deps.finishBuild();
  }});
  assert.deepEqual(await bootstrapIndex(active,initial,{loadBuilder}),{
    outcome:'built-and-activated',collection:next.collection,points:0,
  });
  assert.deepEqual(await load(active),next);
  const requestCount = deps.calls.length;
  assert.equal((await bootstrapIndex(active,`${initial}.absent`,{loadBuilder})).outcome,'already-active');
  assert.equal(builds,1);
  assert.equal(deps.calls.length,requestCount+2);
});

test('bootstrap rejects an incomplete active collection without building again',async t => {
  const {active,initial} = await files(t);
  bootstrapDependencies(t,{exists:true,sealed:true,count:0});
  await save(active,next);
  const loadBuilder = async () => assert.fail('an active profile must not be replaced by bootstrap');
  await assert.rejects(()=>bootstrapIndex(active,initial,{loadBuilder}),/INDEX_INCOMPLETE/);
  assert.deepEqual(await load(active),next);
});

test('manual activation keeps a profile published while its model check ran',async t => {
  const {active} = await files(t);
  await save(active,previous);
  bootstrapDependencies(t,{exists:true,sealed:true,beforeProbe:() => save(active,external)});
  await assert.rejects(()=>activateIndex(active,next),/ACTIVE_PROFILE_CHANGED/);
  assert.deepEqual(await load(active),external);
});

test('index switch builds separately and can be repeated after activation',async t => {
  const {active} = await files(t);
  const old = {...previous,modelRevision:'older'};
  await save(active,old);
  const deps = bootstrapDependencies(t);
  let builds = 0;
  const loadBuilder = async () => ({buildIndex:async (target, previousStore) => {
    assert.deepEqual(target,next);
    assert.equal(previousStore,undefined);
    assert.deepEqual(await load(active),old);
    builds++;
    deps.finishBuild();
  }});
  await assert.rejects(()=>switchIndex(active,{...next,collection:old.collection},{loadBuilder}),/INDEX_COLLECTION_IN_USE/);
  assert.deepEqual(deps.calls,[]);
  assert.deepEqual(await switchIndex(active,next,{loadBuilder}),{
    outcome:'built-and-activated',collection:next.collection,points:0,
  });
  assert.deepEqual(await load(active),next);
  assert.equal((await switchIndex(active,next,{loadBuilder})).outcome,'already-active');
  assert.equal(builds,1);
});

test('index switch refuses to publish after a competing change during the build',async t => {
  const {active} = await files(t);
  await save(active,previous);
  const deps = bootstrapDependencies(t);
  const loadBuilder = async () => ({buildIndex:async () => {
    deps.finishBuild();
    await save(active,external);
  }});
  await assert.rejects(()=>switchIndex(active,next,{loadBuilder}),/ACTIVE_PROFILE_CHANGED/);
  assert.deepEqual(await load(active),external);
  const retryBuilder = async () => assert.fail('sealed candidates may be verified and reused on retry');
  assert.equal((await switchIndex(active,next,{loadBuilder:retryBuilder})).outcome,'activated-existing');
});

test('index switch keeps the old profile if an existing candidate is incomplete',async t => {
  const {active} = await files(t);
  await save(active,previous);
  bootstrapDependencies(t,{exists:true,sealed:true,count:0});
  const loadBuilder = async () => assert.fail('an existing collection must not be overwritten');
  await assert.rejects(()=>switchIndex(active,next,{loadBuilder}),/INDEX_VERIFICATION_FAILED/);
  assert.deepEqual(await load(active),previous);
});

test('rollback uses the active profile observed with its retained target',async t => {
  const {active,ledger} = await files(t);
  await save(ledger,newLedger);
  await save(active,previous);
  const {profile,expected} = await rollbackTarget(active,next.collection);
  assert.equal(expected,profileFingerprint(previous));
  await save(active,external);
  bootstrapDependencies(t,{exists:true,sealed:true});
  await assert.rejects(()=>activateIndex(active,profile,{expected}),/ACTIVE_PROFILE_CHANGED/);
  assert.deepEqual(await load(active),external);
  assert.deepEqual(await load(ledger),newLedger);
});

test('bootstrap reuses a sealed collection and leaves an incomplete candidate untouched',async t => {
  const {active,initial} = await files(t);
  const deps = bootstrapDependencies(t,{exists:true});
  await save(initial,next);
  const loadBuilder = async () => assert.fail('existing collections must not be rebuilt in place');
  await assert.rejects(()=>bootstrapIndex(active,initial,{loadBuilder}),/INDEX_PROFILE_MISMATCH/);
  await assert.rejects(()=>readFile(active),{code:'ENOENT'});
  deps.finishBuild();
  assert.equal((await bootstrapIndex(active,initial,{loadBuilder})).outcome,'activated-existing');
  assert.deepEqual(await load(active),next);
});

test('bootstrap preserves an activation published while the first build ran',async t => {
  const {active,initial} = await files(t);
  const deps = bootstrapDependencies(t);
  await save(initial,next);
  const loadBuilder = async () => ({buildIndex:async () => {
    deps.finishBuild();
    await save(active,external);
  }});
  await assert.rejects(()=>bootstrapIndex(active,initial,{loadBuilder}),/ACTIVE_PROFILE_CHANGED/);
  assert.deepEqual(await load(active),external);
});

test('stopping an idle index watcher does not wait for its sync interval',async t => {
  const {active} = await files(t);
  const lastSuccessAt = 1700000000000;
  await writeWatchStatus(active,{phase:'stopped',attemptedAt:lastSuccessAt,nextAt:null,
    lastSuccessAt,lastFinishedAt:lastSuccessAt,lastOutcome:'updated'});
  const cli = fileURLToPath(new URL('../scripts/knowledge-index/cli.mjs',import.meta.url));
  // Signal events can be injected without relying on Windows process termination semantics.
  const hook = `const write = process.stderr.write.bind(process.stderr);
    process.stderr.write = (chunk, ...args) => {
      if (String(chunk).includes('Knowledge index sync failed:')) {
        setImmediate(() => process.emit('SIGTERM'));
      }
      return write(chunk, ...args);
    };`;
  const {stderr} = await promisify(execFile)(process.execPath,
    ['--import',`data:text/javascript,${encodeURIComponent(hook)}`,cli,'watch'], {
      env:{...process.env,AI_INDEX_ACTIVE_PROFILE:active,AI_INDEX_SYNC_SECONDS:'900'},
      timeout:5000,
    });
  assert.match(stderr,/Knowledge index sync failed:/);
  await assert.rejects(() => readFile(`${active}.lock`),{code:'ENOENT'});
  const {stdout} = await promisify(execFile)(process.execPath,[cli,'watch-status'],{
    env:{...process.env,AI_INDEX_ACTIVE_PROFILE:active},timeout:5000,
  });
  const state = JSON.parse(stdout);
  assert.equal(state.phase,'stopped');
  assert.equal(state.lastOutcome,'failed');
  assert.equal(state.lastSuccessAt,lastSuccessAt);
  assert.equal(state.nextAt,null);
  assert.ok(state.lastFinishedAt >= state.attemptedAt);
});

test('index watcher backs off failed syncs up to the regular interval',async t => {
  const {active} = await files(t);
  const cli = fileURLToPath(new URL('../scripts/knowledge-index/cli.mjs',import.meta.url));
  const hook = `import {readFile} from 'node:fs/promises';
    import {createRequire,syncBuiltinESMExports} from 'node:module';
    const timers = createRequire(${JSON.stringify(cli)})('node:timers/promises');
    const observed = [];
    Date.now = () => 1700000000000;
    timers.setTimeout = async milliseconds => {
      const state = JSON.parse(await readFile(process.env.AI_INDEX_ACTIVE_PROFILE+'.sync-status.json'));
      observed.push({milliseconds,phase:state.phase,outcome:state.lastOutcome,scheduled:state.nextAt-state.updatedAt});
      if (observed.length === 5) {
        console.log(JSON.stringify(observed));
        process.emit('SIGTERM');
      }
    };
    syncBuiltinESMExports();`;
  const {stdout} = await promisify(execFile)(process.execPath,
    ['--import',`data:text/javascript,${encodeURIComponent(hook)}`,cli,'watch'], {
      env:{...process.env,AI_INDEX_ACTIVE_PROFILE:active,AI_INDEX_SYNC_SECONDS:'300'},
      timeout:5000,
    });
  assert.deepEqual(JSON.parse(stdout),[60,120,240,300,300].map(seconds => ({
    milliseconds:seconds*1000,phase:'waiting',outcome:'failed',scheduled:seconds*1000,
  })));
  assert.equal((await readWatchStatus(active)).phase,'stopped');
});

test('watch status reads only diagnostic fields and rejects malformed records',async t => {
  const {active,status} = await files(t);
  assert.equal(await readWatchStatus(active),undefined);
  const time = 1700000000000;
  await save(status,{version:1,phase:'waiting',updatedAt:time,attemptedAt:time,
    nextAt:time+60000,lastSuccessAt:time,lastFinishedAt:time,lastOutcome:'unchanged',ignored:'local fixture'});
  const state = await readWatchStatus(active);
  assert.equal(state.nextAt,time+60000);
  assert.equal(state.lastOutcome,'unchanged');
  assert.equal('ignored' in state,false);
  await save(status,{...state,nextAt:null});
  await assert.rejects(()=>readWatchStatus(active),{message:'SYNC_STATUS_INVALID'});
});

test('readiness and search recover after initial activation, outages and incomplete collections',async t => {
  const {active} = await files(t);
  const reservation = createServer();
  await new Promise((resolve,reject) => reservation.once('error',reject).listen(0,'127.0.0.1',resolve));
  const {port} = reservation.address();
  await new Promise((resolve,reject) => reservation.close(error => error ? reject(error) : resolve()));
  const token = 'fixture-index-readiness-token-1234';
  const environment = {
    AI_INDEX_HOST:'0.0.0.0', AI_INDEX_PORT:String(port),
    AI_INDEX_SERVICE_TOKEN:token, AI_INDEX_QDRANT_URL:'http://index.example.test',
  };
  for (const [key,value] of Object.entries(environment)) {
    const prior = process.env[key];
    process.env[key] = value;
    t.after(() => { if (prior === undefined) delete process.env[key]; else process.env[key] = prior; });
  }
  let available = previous;
  let qdrantReady = false;
  let storedPoints = 3;
  let embeddings = 0;
  let searches = 0;
  const requests = [];
  const fetchHttp = globalThis.fetch;
  t.mock.method(globalThis,'fetch',async (url,options) => {
    const {origin,pathname} = new URL(url);
    if (origin === `http://127.0.0.1:${port}`) return fetchHttp(url,options);
    if (origin === 'http://models.example.test') {
      assert.equal(pathname,'/api/embed');
      embeddings++;
      return Response.json({model:available.model,embeddings:[[1,0,0],[0,1,0]]});
    }
    assert.equal(origin,'http://index.example.test');
    const [, ,collection, ,id] = pathname.split('/');
    requests.push(collection);
    if (!qdrantReady) return new Response(null,{status:503});
    if (collection !== available.collection) return new Response(null,{status:404});
    const reply = result => Response.json({status:'ok',result});
    if (id === 'count') {
      assert.deepEqual(JSON.parse(options.body),{exact:true});
      return reply({count:storedPoints});
    }
    if (id === 'query') {
      searches++;
      return reply({points:[]});
    }
    const marker = {id:'00000000-0000-4000-8000-000000000000',
      payload:{fingerprint:profileFingerprint(available),points:2},vector:[1,0,0]};
    return reply(id === undefined ? [marker] : marker);
  });
  await assert.rejects(() => startIndexServer(undefined),{message:'PROFILE_REQUIRED'});
  await save(active,{});
  await assert.rejects(() => startIndexServer(active),{message:'INVALID_PROFILE'});
  await rm(active);
  process.env.AI_INDEX_QDRANT_URL = '';
  try {
    await assert.rejects(() => startIndexServer(active),{message:'INVALID_URL'});
  } finally {
    process.env.AI_INDEX_QDRANT_URL = environment.AI_INDEX_QDRANT_URL;
  }
  const server = await startIndexServer(active);
  t.after(() => new Promise(resolve => server.close(resolve)));
  const endpoint = `http://127.0.0.1:${port}/internal/v1/knowledge/ready`;
  const anonymous = await fetch(endpoint);
  assert.equal(anonymous.status,401);
  assert.equal(anonymous.headers.get('cache-control'),'no-store');
  await anonymous.json();
  assert.deepEqual(requests,[]);
  const search = () => fetch(`http://127.0.0.1:${port}/internal/v1/knowledge/search`,{
    method:'POST',headers:{authorization:`Bearer ${token}`,'content-type':'application/json'},
    body:JSON.stringify({query:'public fixture',limit:2}),
  });
  await assert.rejects(checkIndexReadiness,/DEPENDENCY_UNAVAILABLE/);
  const uninitialized = await search();
  assert.equal(uninitialized.status,503);
  assert.deepEqual(await uninitialized.json(),{version:1,error:'unavailable'});
  assert.deepEqual(requests,[]);
  assert.equal(embeddings,0);

  await save(active,previous);
  await assert.rejects(checkIndexReadiness,/DEPENDENCY_UNAVAILABLE/);
  assert.deepEqual(requests,[previous.collection]);
  const startupOutage = await search();
  assert.equal(startupOutage.status,503);
  assert.deepEqual(await startupOutage.json(),{version:1,error:'unavailable'});
  qdrantReady = true;
  await checkIndexReadiness();
  storedPoints = 2;
  await assert.rejects(checkIndexReadiness,/DEPENDENCY_UNAVAILABLE/);
  const rejected = await search();
  assert.equal(rejected.status,503);
  assert.deepEqual(await rejected.json(),{version:1,error:'unavailable'});
  assert.equal(embeddings,0);
  assert.equal(searches,0);
  available = next;
  const unavailable = await fetch(endpoint,{headers:{authorization:`Bearer ${token}`}});
  assert.equal(unavailable.status,503);
  assert.deepEqual(await unavailable.json(),{version:1,error:'unavailable'});
  await assert.rejects(checkIndexReadiness,/DEPENDENCY_UNAVAILABLE/);
  await save(active,next);
  storedPoints = 3;
  await checkIndexReadiness();
  const healthy = await search();
  assert.equal(healthy.status,200);
  assert.deepEqual(await healthy.json(),{version:1,candidates:[]});
  assert.equal(embeddings,1);
  assert.equal(searches,1);
  assert.equal(requests.at(-1),next.collection);
});

for (const item of vectors.cases) {
  test(`index publication recovery: ${item.id}`,async t => {
    const {active,ledger,journal} = await files(t);
    const profiles = {previous,next,external};
    const current = profiles[item.active];
    if (current) await save(active,current);
    await save(ledger,oldLedger);
    await save(journal,{version:1,previous:item.noPrevious?null:profileFingerprint(previous),
      next:profileFingerprint(next),ledger:newLedger});

    if (item.expect === 'conflict') {
      await assert.rejects(() => recover(active), /PUBLICATION_CONFLICT/);
      assert.equal((await load(journal)).next,profileFingerprint(next));
    } else {
      assert.deepEqual(await recover(active),{active:current?.collection??null,publication:item.expect});
      await assert.rejects(() => readFile(journal),{code:'ENOENT'});
      assert.deepEqual(await recover(active),{active:current?.collection??null,publication:'none'});
    }
    assert.deepEqual(await load(ledger),item.ledger==='next'?newLedger:oldLedger);
    if (current) assert.deepEqual(await load(active),current);
    else await assert.rejects(() => readFile(active),{code:'ENOENT'});
  });
}

test('a managed publication updates the active file and completes the journal',async t => {
  const {active,ledger,journal} = await files(t);
  await save(active,previous);
  await save(ledger,oldLedger);
  const originalFetch = globalThis.fetch;
  const previousUrl = process.env.AI_INDEX_QDRANT_URL;
  process.env.AI_INDEX_QDRANT_URL = 'http://index.example.test';
  t.after(() => {
    globalThis.fetch = originalFetch;
    if (previousUrl === undefined) delete process.env.AI_INDEX_QDRANT_URL;
    else process.env.AI_INDEX_QDRANT_URL = previousUrl;
  });
  globalThis.fetch = async url => Response.json({status:'ok',result:{
    id:url.split('/').at(-1),payload:{fingerprint:profileFingerprint(next),points:0},
  }});
  await publish(active,next,{expected:profileFingerprint(previous),managed:true});
  assert.deepEqual(await load(active),next);
  const entries = (await load(ledger)).collections;
  assert.deepEqual(entries.map(entry => entry.profile.collection),[previous.collection,next.collection]);
  assert.ok(Number.isSafeInteger(entries[0].retiredAt));
  assert.equal(entries[1].retiredAt,null);
  await assert.rejects(() => readFile(journal),{code:'ENOENT'});
});

for (const condition of [
  'missing','missing-marker','invalid-marker','incomplete','incomplete-build-failed','count-error','transport-error','invalid-exists',
  'profile-changed','profile-changed-during-scan','unchanged','model-drift','stopped-before-publish','stopped-during-publish',
]) {
  test(`automatic index update with ${condition}`, async t => {
    const {active,ledger,journal} = await files(t);
    await save(active,previous);
    await save(ledger,oldLedger);
    const originalFetch = globalThis.fetch;
    const previousUrl = process.env.AI_INDEX_QDRANT_URL;
    process.env.AI_INDEX_QDRANT_URL = 'http://index.example.test';
    t.after(() => {
      globalThis.fetch = originalFetch;
      if (previousUrl === undefined) delete process.env.AI_INDEX_QDRANT_URL;
      else process.env.AI_INDEX_QDRANT_URL = previousUrl;
    });

    const snapshot = 'a'.repeat(64);
    const stop = new AbortController();
    const response = result => Response.json({status:'ok',result});
    const incomplete = ['incomplete','incomplete-build-failed','missing-marker'].includes(condition);
    const changesDuringScan = condition === 'profile-changed-during-scan';
    let candidate, loaded = false, scanned = false, verified = false;
    globalThis.fetch = async (url, options) => {
      if (url.endsWith(`/${previous.collection}/exists`)) {
        if (condition === 'transport-error') return new Response(null,{status:503});
        return response({exists:condition === 'invalid-exists' ? 'false' :
          incomplete || changesDuringScan || ['unchanged','model-drift','count-error','invalid-marker'].includes(condition)});
      }
      if (url.endsWith('/api/embed')) {
        assert.notEqual(condition,'missing-marker');
        return Response.json({model:previous.model,embeddings:[[1,0,0]]});
      }
      if (url.endsWith(`/${previous.collection}/points`) && options.method === 'POST') {
        const {ids} = JSON.parse(options.body);
        if (condition === 'missing-marker') return response([]);
        return response([{id:ids[0],vector:condition === 'model-drift' ? [0,1,0] : [1,0,0],
          payload:{fingerprint:profileFingerprint(condition === 'invalid-marker' ? external : previous),points:2,snapshot}}]);
      }
      if (url.endsWith(`/${previous.collection}/points/count`)) {
        assert.deepEqual(JSON.parse(options.body),{exact:true});
        if (condition === 'count-error') return new Response(null,{status:503});
        return response({count:incomplete ? 2 : 3});
      }
      assert.ok(candidate && url.includes(`/${candidate.collection}/points/`));
      verified = true;
      if (condition === 'stopped-during-publish') stop.abort();
      return response({id:url.split('/').at(-1),payload:{fingerprint:profileFingerprint(candidate),points:2,snapshot}});
    };
    const run = () => syncIndex(active, async () => {
      loaded = true;
      return {
        async snapshotDigest() {
          scanned = true;
          if (changesDuringScan) await save(active,external);
          return snapshot;
        },
        async buildIndex(profile, reusable, {signal}) {
          assert.equal(reusable,undefined);
          assert.equal(signal,stop.signal);
          candidate = profile;
          if (condition === 'incomplete-build-failed') throw Error('FIXTURE_BUILD_FAILED');
          if (condition === 'profile-changed') await save(active,external);
          if (condition === 'stopped-before-publish') stop.abort();
          return {collection:profile.collection,sources:1,points:2,reused:0};
        }
      };
    },{signal:stop.signal});

    if (['missing','missing-marker','incomplete','stopped-during-publish'].includes(condition)) {
      assert.deepEqual(await run(),{changed:true,previous:previous.collection,collection:candidate.collection,
        sources:1,points:2,reused:0,
        ...(incomplete ? {recoveredIncompleteCollection:true} : {recoveredMissingCollection:true})});
      assert.equal(verified,true);
      assert.deepEqual(await load(active),candidate);
      assert.equal((await load(ledger)).collections.at(-1).profile.collection,candidate.collection);
    } else {
      if (condition === 'unchanged') {
        assert.deepEqual(await run(),{changed:false,collection:previous.collection});
      } else if (condition === 'stopped-before-publish') {
        await assert.rejects(run,{name:'AbortError'});
      } else {
        await assert.rejects(run,new RegExp({
          'transport-error':'DEPENDENCY_UNAVAILABLE','invalid-exists':'INDEX_RESPONSE_INVALID',
          'profile-changed':'ACTIVE_PROFILE_CHANGED','profile-changed-during-scan':'ACTIVE_PROFILE_CHANGED',
          'count-error':'DEPENDENCY_UNAVAILABLE','incomplete-build-failed':'FIXTURE_BUILD_FAILED',
          'model-drift':'EMBEDDING_REVISION_MISMATCH','invalid-marker':'INDEX_PROFILE_MISMATCH'
        }[condition]));
      }
      assert.equal(verified,false);
      assert.deepEqual(await load(active),condition === 'profile-changed' || changesDuringScan ? external : previous);
      assert.deepEqual(await load(ledger),oldLedger);
    }
    assert.equal(loaded,!['transport-error','invalid-exists'].includes(condition));
    assert.equal(scanned,condition === 'unchanged' || changesDuringScan);
    assert.equal(Boolean(candidate),incomplete || ['missing','profile-changed','stopped-before-publish','stopped-during-publish'].includes(condition));
    await assert.rejects(() => readFile(journal),{code:'ENOENT'});
    await assert.rejects(() => readFile(`${active}.lock`),{code:'ENOENT'});
  });
}
