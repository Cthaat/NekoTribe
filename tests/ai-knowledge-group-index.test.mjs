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
import { startIndexServer } from '../scripts/knowledge-index/server.mjs';

const publicProfile = {version:1,collection:'neko_knowledge_public_fixture',adapter:'ollama',
  baseUrl:'http://models.example.test',model:'fixture/embed',modelRevision:'v1',dimensions:3,keyEnv:null};
const groupProfile = {...publicProfile,collection:'neko_group_knowledge_fixture',scope:'group'};
const groupCandidate = {kind:'group_post',id:33,version:'a'.repeat(64),chunk:0};
const markerId = '00000000-0000-4000-8000-000000000000';

async function files(t) {
  const directory = await mkdtemp(join(tmpdir(),'neko-group-index-'));
  const paths = {active:join(directory,'active.json'),groupActive:join(directory,'group-active.json'),candidate:join(directory,'candidate.json')};
  t.after(async () => {
    await Promise.all(Object.values(paths).map(path => rm(path,{force:true})));
    await rmdir(directory);
  });
  return paths;
}

const save = (path,value) => writeFile(path,JSON.stringify(value));
const load = async path => JSON.parse(await readFile(path,'utf8'));

test('the group rebuild creates scoped points and publishes only the group profile', async t => {
  const {active,groupActive,candidate} = await files(t);
  await save(active,publicProfile);
  await save(candidate,groupProfile);
  const cli = fileURLToPath(new URL('../scripts/knowledge-index/cli.mjs',import.meta.url));
  const oracle = `import { DatabaseSync } from 'node:sqlite';
  export async function loadOracleDriver() {
    const db = new DatabaseSync(':memory:');
    db.exec(\`
      CREATE TABLE n_groups(group_id INTEGER,privacy,is_active INTEGER,is_deleted INTEGER);
      CREATE TABLE n_users(user_id INTEGER,is_active INTEGER);
      CREATE TABLE n_group_posts(post_id INTEGER,group_id INTEGER,author_id INTEGER,content,is_deleted INTEGER);
      CREATE TABLE n_group_comments(comment_id INTEGER,post_id INTEGER,author_id INTEGER,content,is_deleted INTEGER);
      INSERT INTO n_groups VALUES (12,'private',1,0),(${Number.MAX_SAFE_INTEGER},'public',1,0),
        (14,'private',0,0),(15,'private',1,1);
      INSERT INTO n_users VALUES (1,1),(2,0);
      INSERT INTO n_group_posts VALUES (33,12,1,'group post',0),(34,${Number.MAX_SAFE_INTEGER},1,'other group post',0),
        (35,14,1,'inactive group',0),(36,15,1,'deleted group',0),(37,12,2,'inactive author',0),(38,12,1,'deleted post',1);
      INSERT INTO n_group_comments VALUES (42,33,1,'group comment',0),(43,33,2,'inactive author',0),
        (44,37,1,'inactive parent author',0),(45,38,1,'deleted parent',0),(46,33,1,'deleted comment',1);
    \`);
    return { OUT_FORMAT_OBJECT:1, STRING:1, async getConnection() { return {
      async execute(sql,binds) {
        if (sql === 'SET TRANSACTION READ ONLY') return {};
        const query = sql.replace('FETCH FIRST 100 ROWS ONLY','LIMIT 100');
        return {rows:db.prepare(query).all(binds).map(row => Object.fromEntries(
          Object.entries(row).map(([name,value]) => [name.toUpperCase(),value])
        ))};
      },
      async close() { db.close(); },
    }; } };
  }`;
  const loader = `
    export async function load(url,context,next) {
      if (url.endsWith('/migrate-db.mjs')) return {format:'module',shortCircuit:true,source:${JSON.stringify(oracle)}};
      return next(url,context);
    }`;
  const hook = `
    import assert from 'node:assert/strict';
    import { register } from 'node:module';
    register('data:text/javascript;base64,${Buffer.from(loader).toString('base64')}',import.meta.url);
    const expectedPayloads = [['group_post',33,12],['group_post',34,${Number.MAX_SAFE_INTEGER}],['group_comment',42,12]];
    const markerId = ${JSON.stringify(markerId)};
    const points = new Map();
    let created = false;
    globalThis.fetch = async (url, {body,method}) => {
      const input = body ? JSON.parse(body) : {};
      if (url === 'http://models.example.test/api/embed') {
        return Response.json({model:input.model,embeddings:input.input.map(() => [1,0,0])});
      }
      const path = new URL(url).pathname;
      const root = '/collections/' + process.env.NEKO_TEST_GROUP_COLLECTION;
      assert.ok(path === root || path.startsWith(root + '/'), path);
      const send = result => Response.json({status:'ok',result});
      switch (path.slice(root.length)) {
        case '/exists': return send({exists:created});
        case '':
          assert.equal(method,'PUT');
          created = true;
          return send(true);
        case '/points/count': return send({count:points.size});
        case '/points/query': {
          assert.deepEqual(input.filter.must.find(condition => condition.key === 'scope')?.match,{value:'group'});
          return send({points:[...points.values()].filter(point => point.id !== markerId)});
        }
        case '/points':
          if (method === 'POST') return send([points.get(markerId)]);
          if (process.env.NEKO_TEST_FAIL_GROUP_UPSERT === '1') return new Response(null,{status:503});
          for (const point of input.points) points.set(point.id,point);
          if (points.has(markerId)) {
            assert.deepEqual([...points.values()].filter(point => point.id !== markerId).map(({payload}) => {
              assert.equal(payload.scope,'group');
              assert.deepEqual(Object.keys(payload).sort(),['chunk','group_id','id','kind','scope','version']);
              return [payload.kind,payload.id,payload.group_id];
            }),expectedPayloads);
          }
          return send({status:'completed'});
        case '/points/' + markerId: return send(points.get(markerId));
        default: throw Error('UNEXPECTED_REQUEST');
      }
    };`;
  const run = (args,environment) => promisify(execFile)(process.execPath,
    ['--import',`data:text/javascript;base64,${Buffer.from(hook).toString('base64')}`,cli,...args],{
      env:{...process.env,AI_INDEX_ACTIVE_PROFILE:active,AI_INDEX_GROUP_ACTIVE_PROFILE:groupActive,
        AI_INDEX_QDRANT_URL:'http://index.example.test',AI_INDEX_ORACLE_USER:'fixture',
        AI_INDEX_ORACLE_PASSWORD:'fixture',AI_INDEX_ORACLE_CONNECT:'fixture',
        NEKO_TEST_GROUP_COLLECTION:groupProfile.collection,NEKO_TEST_FAIL_GROUP_UPSERT:'0',...environment},timeout:5000,
    });
  const {stdout} = await run(['rebuild-group',candidate]);
  assert.deepEqual(JSON.parse(stdout),{mode:'rebuild-group',collection:groupProfile.collection,sources:3,points:3,reused:0});
  assert.deepEqual(await load(groupActive),groupProfile);
  assert.deepEqual(await load(active),publicProfile);
  await assert.rejects(run(['activate',candidate]), error => /INVALID_PROFILE/.test(error.stderr));
  await assert.rejects(run(['rebuild-group',active]), error => /INVALID_PROFILE/.test(error.stderr));
  await assert.rejects(run(['rebuild-group',candidate],{AI_INDEX_GROUP_ACTIVE_PROFILE:active}),
    error => /INDEX_ACTIVE_PROFILE_CONFLICT/.test(error.stderr));
  const next = {...groupProfile,collection:'neko_group_knowledge_next'};
  await save(candidate,next);
  await assert.rejects(run(['rebuild-group',candidate],{
    NEKO_TEST_GROUP_COLLECTION:next.collection,NEKO_TEST_FAIL_GROUP_UPSERT:'1',
  }),error => /DEPENDENCY_UNAVAILABLE/.test(error.stderr));
  assert.deepEqual(await load(groupActive),groupProfile);
  assert.deepEqual(await load(active),publicProfile);
});

test('group search checks the precise group before returning candidates', async t => {
  const {active,groupActive} = await files(t);
  await save(active,publicProfile);
  await save(groupActive,groupProfile);
  const reservation = createServer();
  await new Promise((resolve,reject) => reservation.once('error',reject).listen(0,'127.0.0.1',resolve));
  const {port} = reservation.address();
  await new Promise((resolve,reject) => reservation.close(error => error ? reject(error) : resolve()));
  const token = 'fixture-index-group-search-token-1234';
  for (const [name,value] of Object.entries({AI_INDEX_HOST:'127.0.0.1',AI_INDEX_PORT:String(port),
    AI_INDEX_SERVICE_TOKEN:token,AI_INDEX_QDRANT_URL:'http://index.example.test'})) {
    const previous = process.env[name];
    process.env[name] = value;
    t.after(() => { if (previous === undefined) delete process.env[name]; else process.env[name] = previous; });
  }
  const origin = `http://127.0.0.1:${port}`;
  const fetchHttp = globalThis.fetch;
  const groupId = Number.MAX_SAFE_INTEGER;
  const scopedPayload = {...groupCandidate,scope:'group',group_id:groupId};
  let returnedPayloads = [scopedPayload];
  const calls = [];
  t.mock.method(globalThis,'fetch',async (url,options) => {
    const { origin:host,pathname } = new URL(url);
    if (host === origin) return fetchHttp(url,options);
    if (host === publicProfile.baseUrl) return Response.json({model:publicProfile.model,embeddings:[[1,0,0],[0,1,0]]});
    const [, ,collection, ,operation] = pathname.split('/');
    calls.push({collection,operation});
    const profile = collection === groupProfile.collection ? groupProfile : publicProfile;
    const send = result => Response.json({status:'ok',result});
    if (operation === 'count') return send({count:2});
    if (operation === 'query') {
      const body = JSON.parse(options.body);
      if (profile === groupProfile) {
        assert.deepEqual(body.filter.must.find(condition => condition.key === 'scope')?.match, {value:'group'});
        assert.deepEqual(body.filter.must.find(condition => condition.key === 'group_id')?.match, {value:groupId});
        assert.ok(body.with_payload.includes('scope') && body.with_payload.includes('group_id'));
        return send({points:returnedPayloads.map(payload => ({payload}))});
      }
      assert.equal(body.filter.must,undefined);
      return send({points:[]});
    }
    const marker = {id:markerId,vector:[1,0,0],payload:{points:1,fingerprint:profileFingerprint(parseProfile(profile))}};
    return send(operation ? marker : [marker]);
  });
  const server = await startIndexServer(active,groupActive);
  t.after(() => new Promise(resolve => server.close(resolve)));
  const send = (path,body,auth = token) => fetch(`${origin}/internal/v1/knowledge/${path}`,{
    method:'POST',headers:{authorization:`Bearer ${auth}`,'content-type':'application/json','x-neko-knowledge-chunks':'1'},
    body:JSON.stringify(body),
  });
  const groupRequest = {query:'groups',limit:1,group_id:groupId};
  assert.equal((await send('group-search',groupRequest,'bad')).status,401);
  assert.equal((await send('group-search',{...groupRequest,group_id:'12'})).status,400);
  assert.equal((await send('group-search',{...groupRequest,group_id:groupId + 1})).status,400);
  assert.equal((await send('search',groupRequest)).status,400);
  assert.deepEqual(calls,[]);
  const response = await send('group-search',groupRequest);
  assert.equal(response.status,200);
  assert.deepEqual(await response.json(),{version:1,group_id:groupId,candidates:[groupCandidate]});
  assert.ok(calls.every(call => call.collection === groupProfile.collection));
  for (const payload of [groupCandidate,{...scopedPayload,group_id:13},{...scopedPayload,kind:'post'}]) {
    returnedPayloads = [scopedPayload,payload];
    assert.equal((await send('group-search',groupRequest)).status,503);
  }
  await save(groupActive,publicProfile);
  calls.length = 0;
  assert.equal((await send('group-search',groupRequest)).status,503);
  assert.deepEqual(calls,[]);
  const publicResponse = await send('search',{query:'public',limit:1});
  assert.equal(publicResponse.status,200);
  assert.deepEqual(await publicResponse.json(),{version:1,candidates:[]});
  assert.ok(calls.every(call => call.collection === publicProfile.collection));
});
