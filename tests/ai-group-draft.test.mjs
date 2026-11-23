import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { EventEmitter } from 'node:events';
import { Readable } from 'node:stream';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { build } from 'esbuild';

const fixture = JSON.parse(await readFile(new URL('../specifications/scenarios/ai-group-draft.json', import.meta.url)));
const quota = JSON.parse(await readFile(new URL('../specifications/requirements/ai-model-quota.json', import.meta.url)));
const bulk = {
  ...fixture.evidence,posts_count:fixture.bulk.sampleCount,
  examples:Array.from({length:fixture.bulk.sampleCount}, (_,index)=>({
    kind:'post',source_id:index+10,post_id:index+10,excerpt:fixture.bulk.excerpt,
  })),
};
const stubs = {
  '~/server/utils/logging': `export const logInfo=()=>{}; export const getRequestLogContext=()=>null;`,
  h3: `export const defineEventHandler=f=>f,setResponseHeader=(e,k,v)=>e.headers[k]=v,createError=x=>Object.assign(Error(),x);`,
  '~/server/utils/auth-entry-errors': `export const safeV2Action=f=>f();`,
  '~/server/utils/v2': `
    const failure=(statusCode)=>{throw Object.assign(Error(),{statusCode})};
    export const v2BadRequest=()=>failure(400),v2Forbidden=()=>failure(403),v2Conflict=()=>failure(409),
    v2Auth=e=>{if(e.condition==='anonymous')failure(401);return {userId:42}},v2RouterParam=e=>e.id,
    v2Ok=data=>({code:200,data}), v2One=()=>({LAST_SEQUENCE:0}),
    v2Connection=e=>({close:()=>{},condition:e.condition}),v2Throw=(status,message,code)=>failure(status);
  `,
  './conversation-store': `
    export const readConversation=e=>{
      e.loads++;
      return {purpose:e.condition==='wrong_purpose'?'writing':'group',group_id:8};
    };
    export const appendGroupDraft=(e,c,id,input)=>{
      if(e.condition==='changed') throw Object.assign(Error(),{statusCode:409});
      e.appended=input;
      return {message_id:'draft',conversation_id:id,sequence_no:1,role:'assistant'};
    };
  `,
  './group-evidence': `
    export const readGroupEvidence=(e,c,id,query)=>{
      if(id!==8) throw Error('Wrong group');
      if(e.condition==='forbidden'||(e.condition==='revoked_after_proposal'&&e.loads===2)) throw Object.assign(Error(),{statusCode:403});
      globalThis.__groupDraftTestEvent=e;
      e.lookbackDays=query.lookbackDays;
      if(e.loads===2) e.searchTerm=query.searchTerm;
      if(e.loads===2) e.matchExcerpt=query.matchExcerpt;
      const evidence=${JSON.stringify(fixture.evidence)};
      if(e.condition==='trimmed') return ${JSON.stringify(bulk)};
      return e.condition==='empty'||(e.condition==='evidence_gone'&&e.loads===2)?{...evidence,examples:[]}:evidence;
    };
    export const readGroupSentimentEvidence=(e,c,id,query)=>{
      const current=${JSON.stringify(fixture.evidence)};
      if(id!==8 || query.windowEnd!==current.window_end)throw Error('Wrong authenticated sentiment context');
      return {current,previous:{...current,window_end:current.window_start,examples:[]}};
    };
  `,
  './skill-conversation': `export const selectConfiguredConversationSkill=(e,c,scope,skill)=>{
    if(e.condition==='skill_unavailable') throw Error('SKILL_UNAVAILABLE');
    const explicit=JSON.parse(e.scenario.body).skill_id??null;
    if(scope.groupId!==8||skill!==explicit) throw Error('Wrong skill');
    return {configGeneration:e.condition==='skill_changed'&&e.loads===2?7:6,
      skill:{tools:e.condition==='missing_tool_grant'?['public_search']:['public_search','public_statistics']}};
  };`,
  './model-source': `export async function configuredModelRouter() { return {select(role, capabilities) {
    if(role!=='agent'||capabilities.join()!=='tools')throw Error('Wrong model');
    const e=globalThis.__groupDraftTestEvent;
    if(e.condition==='tools_unsupported') throw Error('Unsupported tools');
    const contextWindowTokens=e.condition==='low_budget'?700:e.condition==='trimmed'?${fixture.bulk.context}:8192;
    return {profileId:'model',modelVersion:'group-build',configurationRevision:4,contextWindowTokens,maxOutputTokens:512};
  }}}`,
  './inference-transport': `export class AiInferenceTransport {infer(selection,input) {
    const e=globalThis.__groupDraftTestEvent;
    e.inferences.push(input);
    if(e.inferences.length===1||e.condition==='continued_tool') {
      const calls=e.scenario.tools??${JSON.stringify(fixture.defaultTools)};
      if(e.condition==='cancel_after_proposal') e.node.req.emit('aborted');
      return {finishReason:calls.length?'tool-calls':'stop',text:'无资料时不得保存草稿',toolCalls:calls};
    }
    return {finishReason:'stop',text:'人工审阅草稿',toolCalls:[]};
  }}`,
};
const root = fileURLToPath(new URL('../', import.meta.url));
const routes = await build({
  stdin: { contents: `export { default } from './server/api/v2/ai/conversations/[id]/group-generate.post';`, resolveDir: root },
  bundle: true, write: false, platform: 'node', format: 'esm',
  alias: { '~': root },
  plugins: [{ name: 'fixture-dependencies', setup(bundler) {
    bundler.onResolve({filter:/.*/}, ({path}) => Object.hasOwn(stubs,path) ? {path,namespace:'stub'} : undefined);
    bundler.onLoad({filter:/.*/,namespace:'stub'}, ({path}) => ({contents:stubs[path],loader:'ts'}));
  }}],
});
const route = (await import(`data:text/javascript;base64,${Buffer.from(routes.outputFiles[0].text).toString('base64')}`)).default;

test('group draft route keeps model and storage behind auth, scope and optimistic sequence checks', async t => {
  const environment = {
    AI_MODEL_CONFIG_JSON:'{}',
    AI_SENTIMENTFLOW_ENABLED:'0',
    AI_QUOTA_ACTOR_PER_MINUTE:String(quota.actorLimit),
    AI_QUOTA_SERVICE_PER_MINUTE:String(quota.serviceLimit),
  };
  const previous = Object.fromEntries(Object.keys(environment).map(key=>[key,process.env[key]]));
  Object.assign(process.env,environment);
  t.after(() => {
    for (const [key,value] of Object.entries(previous)) {
      if (value===undefined) delete process.env[key];
      else process.env[key]=value;
    }
    delete globalThis.__groupDraftTestEvent;
  });
  for (const entry of [...fixture.cases, {
    id:'cancel',condition:'cancel_after_proposal',body:'{"kind":"faq","expected_sequence":0}',http:503,loads:1,inferences:1,reservations:1,
  }]) {
    const event = { condition:entry.condition, scenario:entry, id:'conversation', headers:{},loads:0,inferences:[],
      reservations:0,context:{aiQuotaRedis:{eval:async(lua,count,...args)=>{
        event.reservations++;
        assert.equal(lua,quota.lua);
        assert.equal(count,2);
        assert.deepEqual(args,[`${quota.keyPrefix}:actor:42`,`${quota.keyPrefix}:service`,2,quota.actorLimit,quota.serviceLimit,60000,100000]);
        if(entry.condition==='quota_unavailable') throw new Error('offline');
        return entry.retryAfter ?? 0;
      }}},
      node:{req:Readable.from([Buffer.from(entry.body)]),res:new EventEmitter()} };
    if (entry.http === 200) {
      assert.equal((await route(event)).data.status, entry.status, entry.id);
    } else {
      await assert.rejects(() => route(event), error => error.statusCode === entry.http, entry.id);
    }
    assert.equal(event.headers['Cache-Control'], 'private, no-store');
    assert.equal(event.headers['Retry-After'],entry.retryAfter,entry.id);
    assert.equal(event.reservations,entry.reservations,entry.id);
    assert.equal(event.loads, entry.loads, entry.id);
    assert.equal(event.inferences.length,entry.inferences,entry.id);
    if (event.inferences.length) {
      const intro=event.inferences[0];
      const {kind,search_term} = JSON.parse(entry.body);
      assert.deepEqual(JSON.parse(intro.messages[1].content),{kind,...(search_term === undefined ? {} : {search_term})});
      assert.equal(intro.messages[0].content.includes('标为待确认'), entry.id === 'activity-plan-generated');
      assert.deepEqual(intro.tools.map(tool=>tool.name),['public_search','public_statistics']);
      assert.doesNotMatch(JSON.stringify(intro),/公开资料<&🐱/);
    }
    if (event.inferences.length===2) {
      const calls=entry.tools??fixture.defaultTools;
      const source=entry.condition==='trimmed'?{...bulk,examples:bulk.examples.slice(0,fixture.bulk.sampleUsed)}:fixture.evidence;
      const followup=event.inferences[1];
      assert(!Object.hasOwn(followup,'tools'));
      assert.deepEqual(followup.messages[2],{role:'assistant',content:'',toolCalls:calls});
      const window={window_start:source.window_start,window_end:source.window_end};
      assert.deepEqual(followup.messages.slice(3).map(row=>({id:row.toolCallId,...JSON.parse(row.content)})),calls.map(call=>({
        id:call.id,...window,...(call.name==='public_search'?{examples:source.examples}:
          {posts_count:source.posts_count,comments_count:source.comments_count}),
      })));
    }
    if (entry.status === 'generated') {
      assert.equal(event.lookbackDays, JSON.parse(entry.body).kind==='weekly_report'?7:30);
      assert.equal(event.appended.draft.kind, JSON.parse(entry.body).kind);
      assert.equal(event.appended.draft.source_digest, entry.condition==='trimmed'?fixture.bulk.digest:fixture.digest);
      assert.equal(event.appended.draft.example_count, entry.condition==='trimmed'?fixture.bulk.sampleUsed:fixture.evidence.examples.length);
      assert.equal(event.appended.draft.skill_generation, 6);
      assert.equal(event.appended.expectedSequence, 0);
      assert.equal(event.appended.modelVersion, 'group-build');
      assert.deepEqual(event.appended.draft.tools_used,(entry.tools??fixture.defaultTools).map(call=>call.name));
      if(entry.condition === 'focused_search' || entry.condition === 'admin_search') {
        assert.equal(event.searchTerm, '活动报名');
        assert.equal(event.appended.draft.search_term, '活动报名');
        assert.equal(event.matchExcerpt, true);
        assert.equal(event.appended.draft.match_excerpt, true);
      }
    } else assert.equal(event.appended, undefined);
  }
});

test('the optional group tool preserves drafts on upstream failure and saves only verified sample use', async t => {
  const env = {AI_SENTIMENTFLOW_ENABLED:'1',AI_SENTIMENTFLOW_URL:'http://sentiment.fixture.test/predict/'};
  const previous = Object.fromEntries(Object.keys(env).map(key=>[key,process.env[key]]));
  Object.assign(process.env,env);
  t.after(()=>{
    for (const [key,value] of Object.entries(previous)) {
      if (value===undefined) delete process.env[key]; else process.env[key]=value;
    }
    delete globalThis.__groupDraftTestEvent;
  });
  let available = true;
  t.mock.method(globalThis,'fetch',async (url,options) => {
    assert.equal(url.href,env.AI_SENTIMENTFLOW_URL);
    assert.equal(options.redirect,'error');
    assert(fixture.evidence.examples.some(example=>example.excerpt===JSON.parse(options.body).text));
    return available ? Response.json({prediction:{label:'slightly_negative',confidence:0.8}}) : new Response(null,{status:503});
  });
  const name = 'community_sentiment_summary';
  const body = '{"kind":"weekly_report","expected_sequence":0}';
  for (const success of [true,false]) {
    available = success;
    const event = {condition:'sentiment',scenario:{body,tools:[...fixture.defaultTools,{id:'sentiment-tool',name,arguments:{}}]},
      id:'conversation',headers:{},loads:0,inferences:[],
      node:{req:Readable.from([Buffer.from(body)]),res:new EventEmitter()},
      context:{aiQuotaRedis:{eval:async()=>0}}};
    assert.equal((await route(event)).data.status,'generated');
    const input = event.inferences.at(-1).messages.find(message=>message.toolCallId==='sentiment-tool');
    const actual = JSON.parse(input.content);
    if (success) {
      assert.equal(actual.status,'available');
      assert.equal(actual.current.negative,fixture.evidence.examples.length);
      assert.equal(actual.negative_share_change,null);
      assert.match(event.appended.draft.sentiment_source_digest,/^[0-9a-f]{64}$/);
      assert(event.appended.draft.tools_used.includes(name));
    } else {
      assert.deepEqual(actual,{status:'unavailable'});
      assert.equal(event.appended.draft.sentiment_source_digest,undefined);
      assert(!event.appended.draft.tools_used.includes(name));
    }
  }
});
