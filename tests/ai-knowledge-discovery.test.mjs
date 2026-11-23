import assert from 'node:assert/strict';
import { test } from 'node:test';
import { build } from 'esbuild';
import { fileURLToPath } from 'node:url';
import { readFileSync } from 'node:fs';
import { parseProfile, profileFingerprint } from '../scripts/knowledge-index/config.mjs';
import { buildIndex } from '../scripts/knowledge-index/build.mjs';
import { indexStore } from '../scripts/knowledge-index/qdrant.mjs';
import * as indexOracle from '../scripts/knowledge-index/oracle.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const stubs = {
  '~/server/database/readiness': `export const requireFeatureSchema=async()=>{};`,
  oracledb: `export default {OUT_FORMAT_OBJECT:4002,STRING:{num:2001}};`,
  '~/server/utils/v2': `export const v2Auth=e=>{if(!e.userId)throw Error('401');return {userId:e.userId}};export const v2BadRequest=()=>{throw Error('400')};export const v2ServerError=()=>{throw Error('500')};export const v2Forbidden=()=>{throw Error('403')};export const v2Conflict=()=>{throw Error('409')}; export const v2One=async(c,sql,binds)=>(await c.execute(sql,binds)).rows?.[0];`
};
const built = await build({stdin:{contents:`export * from './server/services/ai/knowledge-source.ts';export {runKnowledgeTurn} from './server/services/ai/knowledge-turn.ts';export {discoverIndexedSources} from './server/services/ai/knowledge-index.ts'`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'discovery-stubs',setup(b){b.onResolve({filter:/.*/},a=>{if(Object.hasOwn(stubs,a.path))return {path:a.path,namespace:'stub'}});b.onLoad({filter:/.*/,namespace:'stub'},a=>({contents:stubs[a.path],loader:'js'}))}}]});
const {discoverKnowledgeSources,hydrateKnowledgeSources,sourceVersion,runKnowledgeTurn,discoverIndexedSources} = await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);

test('index snapshot uses public group tables and matches live source versions', async () => {
  const connection = {async execute(sql, binds) {
    assert.deepEqual(binds, {after_id:0,max_id:999_999_999_999_999});
    const comment = /FROM n_(?:group_)?comments/i.test(sql);
    assert.match(sql, comment ? /c\.comment_id<=:max_id/ : /p\.post_id<=:max_id/);
    if (comment) assert.match(sql, /p\.post_id BETWEEN 1 AND :max_id/);
    if (!/FROM n_group_/i.test(sql)) return {rows:[]};
    assert.match(sql, /p\.group_id BETWEEN 1 AND :max_id/);
    assert.match(sql, /g\.privacy='public' AND g\.is_active=1 AND g\.is_deleted=0/);
    assert.match(sql, /p\.is_deleted=0/);
    assert.match(sql, /a\.is_active=1/);
    if (comment) {
      assert.match(sql, /c\.is_deleted=0/);
      assert.match(sql, /ca\.is_active=1/);
    }
    return {rows:[{SOURCE_ID: comment ? 21 : 11, POST_ID:11, CONTENT:'猫'}]};
  }};
  const sources = await Array.fromAsync(indexOracle.readPublicSources(connection, {}));
  assert.deepEqual(sources, [
    {kind:'group_post',id:11,version:sourceVersion('group_post',11,11,'猫'),content:'猫'},
    {kind:'group_comment',id:21,version:sourceVersion('group_comment',21,11,'猫'),content:'猫'},
  ]);
});

test('Oracle source preflight checks all source families and reports only safe failures', async () => {
  const queries = [];
  const connection = {
    async execute(sql, binds) {
      queries.push(sql);
      if (sql.includes('n_ai_terms_active')) return {rows:[]};
      assert.match(sql, /^SELECT \* FROM \([\s\S]+\) WHERE 1=0$/);
      assert.deepEqual(binds, {after_id:0,max_id:999_999_999_999_999});
      if (sql.includes('FROM n_group_comments')) throw Error('private Oracle error detail');
      return {rows:[]};
    },
  };
  const result = await indexOracle.checkPublicSources(connection, {});
  assert.equal(queries.length, 5);
  assert.deepEqual(result, {
    ready:false,
    results:[
      {source:'post',ok:true},
      {source:'comment',ok:true},
      {source:'group_post',ok:true},
      {source:'group_comment',ok:false,code:'SOURCE_READ_UNAVAILABLE'},
      {source:'terms',ok:true,published:false},
    ],
  });
  assert.doesNotMatch(JSON.stringify(result), /private Oracle/);
});

test('index builds stop before embedding or creating a collection without an Oracle source', async t => {
  const keys = ['AI_INDEX_ORACLE_USER','AI_INDEX_ORACLE_PASSWORD','AI_INDEX_ORACLE_CONNECT'];
  const previous = keys.map(key => process.env[key]);
  const originalFetch = globalThis.fetch;
  t.after(() => {
    globalThis.fetch = originalFetch;
    for (const [index,key] of keys.entries()) {
      if (previous[index] === undefined) delete process.env[key];
      else process.env[key] = previous[index];
    }
  });
  for (const key of keys) delete process.env[key];
  let networkCalls = 0;
  globalThis.fetch = async () => {
    networkCalls++;
    throw Error('Unexpected model or collection access');
  };
  const profile = parseProfile({version:1,collection:'neko_knowledge_fixture',adapter:'ollama',
    baseUrl:'http://models.example.test',model:'fixture/embed',modelRevision:'a1',dimensions:3,keyEnv:null});
  const progress = [];
  await assert.rejects(buildIndex(profile,undefined,{onProgress:entry=>progress.push(entry.stage)}), /ORACLE_CONFIG_REQUIRED/);
  assert.equal(networkCalls,0);
  assert.deepEqual(progress,['checking-sources']);
});

test('legacy index requests exclude group points before ranking', async t => {
  const previous = process.env.AI_INDEX_QDRANT_URL;
  process.env.AI_INDEX_QDRANT_URL = 'http://qdrant.example.test';
  const originalFetch = globalThis.fetch;
  t.after(() => {
    globalThis.fetch = originalFetch;
    if (previous === undefined) delete process.env.AI_INDEX_QDRANT_URL;
    else process.env.AI_INDEX_QDRANT_URL = previous;
  });
  const store = indexStore(parseProfile({version:1, collection:'neko_knowledge_groups_fixture', adapter:'ollama',
    baseUrl:'http://models.example.test', model:'fixture/embed', modelRevision:'a1', dimensions:3, keyEnv:null}));
  const group = {kind:'group_post',id:11,version:'a'.repeat(64),chunk:2};
  const ordinary = {...group,kind:'post'};
  globalThis.fetch = async (_url,options) => {
    const excluded = JSON.parse(options.body).filter.must_not;
    if (excluded.length > 1) assert.deepEqual(excluded[1], {key:'kind',match:{any:['group_post','group_comment']}});
    return Response.json({status:'ok',result:{points:(excluded.length > 1 ? [ordinary] : [group,ordinary]).map(payload=>({payload}))}});
  };
  assert.deepEqual(await store.search([1,0,0],2,undefined,{includeGroups:false}), [ordinary]);
  assert.deepEqual(await store.search([1,0,0],2), [group,ordinary]);
});

test('the stored embedding probe permits normalization and blocks same-dimension drift', async t => {
  const profile = parseProfile({ version:1, collection:'neko_knowledge_fixture', adapter:'ollama',
    baseUrl:'http://models.example.test', model:'fixture/embed', modelRevision:'a1', dimensions:3, keyEnv:null });
  const fixture = JSON.parse(readFileSync(new URL('../specifications/scenarios/ai-knowledge-embedding-probe.json', import.meta.url)));
  const originalFetch = globalThis.fetch;
  const previous = process.env.AI_INDEX_QDRANT_URL;
  process.env.AI_INDEX_QDRANT_URL = 'http://qdrant.example.test';
  t.after(() => {
    globalThis.fetch = originalFetch;
    if (previous === undefined) delete process.env.AI_INDEX_QDRANT_URL;
    else process.env.AI_INDEX_QDRANT_URL = previous;
  });
  const store = indexStore(profile);
  for (const item of fixture.cases) {
    globalThis.fetch = async (url, options) => {
      assert.equal(url, 'http://qdrant.example.test/collections/neko_knowledge_fixture/points');
      assert.equal(options.method, 'POST');
      const { ids, with_payload: withPayload, with_vector: withVector } = JSON.parse(options.body);
      assert.equal(ids.length, 1);
      assert.equal(withPayload, true);
      assert.equal(withVector, true);
      return Response.json({ status:'ok', result:[{ id:ids[0], vector:item.stored,
        payload:{ fingerprint:profileFingerprint(profile), points:0 } }] });
    };
    if (item.expect === 'match') assert.equal((await store.checkEmbedding(item.live)).points, 0, item.id);
    else await assert.rejects(() => store.verify(item.live), /EMBEDDING_REVISION_MISMATCH/, item.id);
  }
});

test('only eligible index failures opt into lexical discovery', async t => {
  const vectors = JSON.parse(readFileSync(new URL('../specifications/scenarios/ai-knowledge-index-fallback.json', import.meta.url)));
  for (const name of ['AI_KNOWLEDGE_INDEX_URL', 'AI_KNOWLEDGE_INDEX_FALLBACK', 'AI_INDEX_SERVICE_TOKEN']) {
    const previous = process.env[name];
    t.after(() => { if (previous === undefined) delete process.env[name]; else process.env[name] = previous; });
  }
  process.env.AI_INDEX_SERVICE_TOKEN = 'x'.repeat(32);
  const originalFetch = globalThis.fetch;
  t.after(() => { globalThis.fetch = originalFetch; });
  for (const item of vectors.cases) {
    process.env.AI_KNOWLEDGE_INDEX_URL = item.address ?? 'http://index.example.test';
    process.env.AI_KNOWLEDGE_INDEX_FALLBACK = item.fallback;
    let requests = 0;
    globalThis.fetch = async (url, options) => {
      requests++;
      assert.equal(options.redirect, 'manual');
      assert.equal(options.headers['x-neko-knowledge-group-sources'], '1');
      if (item.id === 'ipv6-proxy-prefix') assert.equal(url,'http://[::1]:3818/retrieval/internal/v1/knowledge/search');
      if (item.transportError) throw new TypeError('network failure');
      return new Response(item.body ?? null, { status: item.status });
    };
    const request = new AbortController();
    if (item.cancel) request.abort();
    const discover = () => discoverIndexedSources(item.query ?? 'cats', item.limit ?? 20, request.signal);
    if (item.expect === 'error') await assert.rejects(discover, undefined, item.id);
    else if (item.expect === 'group') assert.deepEqual(await discover(), [
      {kind:'group_comment',id:21,version:'a'.repeat(64),chunk:2},
    ],item.id);
    else assert.deepEqual(await discover(), item.expect === 'lexical' ? null : [], item.id);
    if (item.noRequest) assert.equal(requests,0,item.id);
  }
  globalThis.fetch = async (_url, options) => {
    assert.deepEqual(JSON.parse(options.body), {query:'猫',limit:20});
    return Response.json({version:1,candidates:[]});
  };
  assert.deepEqual(await discoverIndexedSources('　猫　',20), []);
  for (const [query,limit] of [['',1],['a\u0000b',1],['猫'.repeat(86),1],['猫',0],['猫',21],['猫',1.5]]) {
    await assert.rejects(() => discoverIndexedSources(query,limit), /INDEX_QUERY_INVALID/);
  }
});

test('discovers public matching posts and comments using viewer-bound queries', async () => {
  const calls=[];
  const db={async execute(sql,binds,options){
    calls.push({sql,binds});
    assert.equal(binds.viewer_id,42); assert.equal(binds.term,'猫'); assert.equal(binds.row_limit,2);
    assert.equal(binds.max_id,999_999_999_999_999);
    assert.match(sql,/p\.post_id BETWEEN 1 AND :max_id/);
    if (/FROM n_(?:group_)?comments/i.test(sql)) assert.match(sql,/c\.comment_id BETWEEN 1 AND :max_id/);
    if (/FROM n_group_/i.test(sql)) {
      assert.match(sql,/p\.group_id BETWEEN 1 AND :max_id/);
      assert.match(sql,/g\.privacy='public' AND g\.is_active=1 AND g\.is_deleted=0/);
      assert.match(sql,/INSTR\([pc]\.content,:term\)>0/);
      assert.match(sql,/FETCH FIRST :row_limit ROWS ONLY/);
      return {rows:[]};
    }
    assert.match(sql,/p\.visibility\s*=\s*'public'/i);
    assert.match(sql,/p\.is_deleted\s*=\s*0/i);
    assert.match(sql,/fn_can_view_post\(:viewer_id\s*,\s*p\.post_id\)\s*=\s*1/i);
    assert.match(sql,/post_author\.is_active=1/);
    assert.match(sql,/DBMS_LOB\.INSTR\([^,]+,\s*:term\)\s*>\s*0/i);
    assert.match(sql,/DBMS_LOB\.GETLENGTH\([^)]+\) BETWEEN 1 AND 65536/i);
    assert.deepEqual(options.fetchTypeHandler({name:'CONTENT'}),{type:{num:2001}});
    if (/FROM n_comments/i.test(sql)) {
      assert.match(sql,/c\.is_deleted\s*=\s*0/i);
      assert.match(sql,/comment_author\.is_active=1/);
      assert.match(sql,/b\.user_id=:viewer_id AND b\.target_user_id=c\.user_id/);
      assert.match(sql,/b\.target_user_id=:viewer_id AND b\.user_id=c\.user_id/);
      return {rows:[{SOURCE_ID:21,POST_ID:11,CONTENT:'评论猫'}]};
    }
    return {rows:[{SOURCE_ID:11,POST_ID:11,CONTENT:'帖子猫'},{SOURCE_ID:10,POST_ID:10,CONTENT:'旧帖子猫'}]};
  }};
  const result=await discoverKnowledgeSources({userId:42},db,' 猫 ',2);
  assert.equal(calls.length,4);
  assert.deepEqual(result,[{kind:'post',id:11,post_id:11,content:'帖子猫',version:sourceVersion('post',11,11,'帖子猫')},{kind:'comment',id:21,post_id:11,content:'评论猫',version:sourceVersion('comment',21,11,'评论猫')}]);
});

test('includes matching public rules in the shared round robin only with active authority',async()=>{
 const vectors=JSON.parse(readFileSync(new URL('../specifications/scenarios/ai-public-terms-source-vectors.json',import.meta.url),'utf8'));let enabled=1;
 const db={async execute(sql){if(/FROM\s+n_ai_terms_active/i.test(sql))return {rows:[{CATALOG_DIGEST:vectors.catalog_digest,GENERATION:1,ENABLED:enabled}]};if (/FROM n_group_/i.test(sql)) return {rows:[]};return {rows:/FROM n_comments/i.test(sql)?[{SOURCE_ID:21,POST_ID:11,CONTENT:'账户评论'}]:[{SOURCE_ID:11,POST_ID:11,CONTENT:'账户帖子'}]}}};
 const result=await discoverKnowledgeSources({userId:42},db,'账户',3);
 assert.deepEqual(result.map(x=>x.kind),['post','comment','terms']);assert.equal(result[2].id,2);assert.equal(result[2].version,vectors.versions[1].version);assert(!('post_id' in result[2]));
 enabled=0;await assert.rejects(()=>discoverKnowledgeSources({userId:42},db,'账户',3));
});
test('matches shared three-backend discovery order vectors',async()=>{
 const vectors=JSON.parse(readFileSync(new URL('../specifications/scenarios/ai-knowledge-discovery-order.json',import.meta.url),'utf8'));
 const digest=JSON.parse(readFileSync(new URL('../specifications/scenarios/ai-public-terms-source-vectors.json',import.meta.url),'utf8')).catalog_digest;
 for(const item of vectors.cases){
  const db={async execute(sql,binds){
    if(/FROM\s+n_ai_terms_active/i.test(sql)) return {rows:[{CATALOG_DIGEST:digest,GENERATION:1,ENABLED:item.authority==='enabled'?1:0}]};
    const group=/FROM n_group_/i.test(sql), comments=/FROM n_(?:group_)?comments/i.test(sql);
    const ids = group ? (comments ? item.groupComments : item.groupPosts) : (comments ? item.comments : item.posts);
    return {rows:(ids ?? []).slice(0,binds.row_limit).map(id=>({
      SOURCE_ID:id,POST_ID:comments?11:id,CONTENT:`${item.query} ${id}`,...(group ? {GROUP_ID:7} : {}),
    }))};
  }};
  const work=()=>discoverKnowledgeSources({userId:42},db,item.query,item.limit);
  if(item.error)await assert.rejects(work,undefined,item.id);else assert.deepEqual((await work()).map(x=>`${x.kind}:${x.id}`),item.expected,item.id);
 }
});
test('rule disabled during inference is never delivered by the real discovery and hydration chain',async()=>{
 const vectors=JSON.parse(readFileSync(new URL('../specifications/scenarios/ai-public-terms-source-vectors.json',import.meta.url),'utf8'));let enabled=1,seen;
 const db={async execute(sql){return /FROM\s+n_ai_terms_active/i.test(sql)?{rows:[{CATALOG_DIGEST:vectors.catalog_digest,GENERATION:1,ENABLED:enabled}]}:{rows:[]}}};
 const actor={userId:42};const deps={discover:()=>discoverKnowledgeSources(actor,db,'账户',2),hydrate:refs=>hydrateKnowledgeSources(actor,db,refs),infer:async sources=>{seen=sources;enabled=0;return 'answer'}};
 await assert.rejects(()=>runKnowledgeTurn(deps));assert.equal(seen[0].kind,'terms');assert.equal(seen[0].id,2);
});

test('the lexical group hit is rechecked if its group becomes private during inference', async () => {
  const actor = {userId:42};
  const source = {SOURCE_ID:21,POST_ID:11,GROUP_ID:7,CONTENT:'群猫评论'};
  let publicGroup = true;
  const db = {async execute(sql) {
    if (!/FROM n_group_comments/i.test(sql)) return {rows:[]};
    assert.match(sql, /g\.privacy='public'/);
    return {rows:publicGroup ? [source] : []};
  }};
  await assert.rejects(() => runKnowledgeTurn({
    discover: () => discoverKnowledgeSources(actor, db, '猫', 2),
    hydrate: refs => hydrateKnowledgeSources(actor, db, refs),
    infer: async ([row]) => {
      assert.equal(row.kind, 'group_comment');
      assert.equal(row.group_id, 7);
      publicGroup = false;
      return 'answer';
    },
  }), /SOURCE_CHANGED/);
});

test('a stale index batch can refresh once and only the current version reaches inference', async () => {
 const original = {kind:'post',id:11,version:'a'.repeat(64),chunk:17};
 const fresh = {kind:'post',id:11,version:'b'.repeat(64)};
 const hydrated = {...fresh,post_id:11,content:'edited post'};
 let refreshes = 0;
 const deps = {
  discover: async () => [original],
  hydrate: async hits => hits[0]?.version === fresh.version ? [hydrated] : [],
  refreshStale: async hits => { assert.deepEqual(hits, [original]); refreshes++; return [fresh]; },
  selectEvidence: (sources, hits) => { assert.deepEqual(hits, [fresh]); return sources; },
  infer: async sources => { assert.deepEqual(sources, [hydrated]); return 'answer'; }
 };
 assert.deepEqual(await runKnowledgeTurn(deps), {answer:'answer',sources:[fresh]});
 assert.deepEqual(await runKnowledgeTurn({...deps,discover:async()=>[]}), {answer:null,sources:[]});
 assert.equal(refreshes, 1);
});

test('rejects unauthorized and invalid searches without querying',async()=>{
  const db={execute(){throw Error('must not query')}};
  await assert.rejects(()=>discoverKnowledgeSources({},db,'test',1),/401/);
  for(const [term,limit] of [['',1],['\u0000test',1],['x'.repeat(257),1],['\ud800',1],['ok',0],['ok',21],['ok',1.5]]) {
    await assert.rejects(()=>discoverKnowledgeSources({userId:42},db,term,limit),/400/);
  }
});

test('omits oversized sources and rejects corrupt or duplicate rows',async()=>{
  const actor={userId:42};
  const withRows=rows=>({async execute(sql){return {rows:/FROM n_posts/i.test(sql)?rows:[]}}});
  assert.deepEqual(await discoverKnowledgeSources(actor,withRows([{SOURCE_ID:1,POST_ID:1,CONTENT:'猫'.repeat(21846)}]),'猫',2),[]);
  for(const rows of [[{SOURCE_ID:1,POST_ID:2,CONTENT:'text'}],[{SOURCE_ID:1,POST_ID:1,CONTENT:'\ud800'}],[{SOURCE_ID:1,POST_ID:1,CONTENT:'a'},{SOURCE_ID:1,POST_ID:1,CONTENT:'a'}]]) {
    await assert.rejects(()=>discoverKnowledgeSources(actor,withRows(rows),'text',2),/500/);
  }
});
