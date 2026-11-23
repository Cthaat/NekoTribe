import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { EventEmitter } from 'node:events';
import { Readable } from 'node:stream';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { build } from 'esbuild';

const root=fileURLToPath(new URL('../',import.meta.url));
const spec=JSON.parse(readFileSync(root+'specifications/scenarios/ai-moderation-advice-http.json','utf8'));
const stubs={
  '~/server/storage': `import {Readable} from 'node:stream';
    export const getStorageProvider=()=>({async readObject(key){
      if(key!=='posts/test.png')throw Error('unexpected image read');
      return {statusCode:200,stream:Readable.from([Buffer.from('iVBORw0KGgo=','base64')])};
    }});`,
  '~/server/utils/logging':`export const logInfo=(scope,event)=>{globalThis.__moderationCase.audit=event}; export const getRequestLogContext=()=>null;`,
  h3:`export const defineEventHandler=f=>f,setResponseHeader=(e,k,v)=>e.headers[k]=v,createError=x=>Object.assign(Error(),x);`,
  '~/server/utils/auth-entry-errors':'export const safeV2Action=f=>f();',
  '~/server/utils/v2':`
    const failure=statusCode=>{throw Object.assign(Error(),{statusCode});};
    export const v2Auth=e=>{if(e.condition==='anonymous')failure(401);return {userId:1}},v2RouterParam=e=>e.id,v2Ok=data=>({data}),
      v2BadRequest=()=>failure(400),v2Forbidden=()=>failure(403),v2Conflict=()=>failure(409),v2ServerError=()=>failure(500),v2Throw=failure,
      v2Connection=e=>({close:()=>{},condition:e.condition}),
      v2One=(c,sql)=>sql.includes('a.media_id=:media_id')
        ? c.condition==='vision-stale' ? null : image
        : {LAST_SEQUENCE:0},
      v2Rows=(c,query,binds)=>{
        if(query.includes('JOIN n_post_media'))return [image];
        if(c.condition==='empty')return [];
        if(c.condition.startsWith('vision'))return [{POST_ID:binds.target_id,GROUP_ID:null,CONTENT:null,TEXT_LENGTH:0}];
        return [{POST_ID:binds.target_id,GROUP_ID:null,CONTENT:${JSON.stringify(spec.text)},TEXT_LENGTH:${spec.text.length}}];
      };
    const image={MEDIA_ID:9,STORAGE_KEY:'posts/test.png',ACCESS_SCOPE:'public',MIME_TYPE:'image/png',FILE_SIZE:8};
  `,
  './conversation-store':`
    export const readConversation=e=>{
      if(e.condition==='forbidden')throw Object.assign(Error(),{statusCode:403});
      return {purpose:e.condition==='wrong_purpose'?'writing':'moderation'};
    };
    export const appendModerationAdvice=(e,conn,id,input)=>{
      if(e.condition==='changed')throw Object.assign(Error(),{statusCode:409});
      e.saved=input;
      return {message_id:'review',conversation_id:id,role:'assistant',sequence_no:1};
    };
  `,
  './skill-conversation':`export const selectConfiguredConversationSkill=(e,c,s,skill)=>{
    if(e.condition==='disabled')throw Error('SKILL_UNAVAILABLE');
    if(s.purpose!=='moderation'||(skill!==null && skill!=='moderation-advice'))throw Error('Wrong skill');
    e.selectedSkill=skill;
    return {configGeneration:4};
  };`,
  './public-terms-authority':`export const readTermsAuthority=e=>{
    if(e.condition==='terms_unavailable')throw Error('TERMS_AUTHORITY_UNAVAILABLE');
    return {digest:'a'.repeat(64),generation:9};
  };`,
  './model-source':`export async function configuredModelRouter() { return {
    select(role, caps) {
      if(role!=='moderation'||caps[0]!=='structured-output')throw Error('Wrong binding');
      const vision=globalThis.__moderationCase.condition.startsWith('vision');
      return {profileId:'reviewer',modelVersion:'reviewer-build',configurationRevision:6,contextWindowTokens:8192,maxOutputTokens:512,
        capabilities:vision ? ['structured-output','vision'] : ['structured-output']};
    }
  }}`,
  './inference-transport':`export class AiInferenceTransport {
    infer(model,input) {
      const e=globalThis.__moderationCase;
      e.inference=input;
      const answer=${JSON.stringify(spec.goodAdvice)};
      if(e.condition==='fabricated_rule')answer.rule_ids=[999];
      if(e.condition==='wrong_locale')answer.rule_ids=[7];
      return {finishReason:'stop',text:JSON.stringify(answer),toolCalls:e.condition==='tool_proposal'?[{}]:[]};
    }
  }`,
};
const compiled=await build({
  stdin:{contents:`export {default} from './server/api/v2/ai/conversations/[id]/moderation-generate.post';`,resolveDir:root},
  alias:{'~':root},bundle:true,write:false,platform:'node',format:'esm',
  plugins:[{name:'moderation-boundaries',setup(builder){
    builder.onResolve({filter:/.*/},({path})=>Object.hasOwn(stubs,path)?{path,namespace:'stub'}:undefined);
    builder.onLoad({filter:/.*/,namespace:'stub'},({path})=>({contents:stubs[path],loader:'ts'}));
  }}],
});
const handler=(await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`)).default;

test('moderation advises only with vetted evidence, model output and cited rules',async t=>{
  const previous=process.env.AI_MODEL_CONFIG_JSON;
  process.env.AI_MODEL_CONFIG_JSON='{}';
  t.after(()=>{
    if(previous===undefined)delete process.env.AI_MODEL_CONFIG_JSON;
    else process.env.AI_MODEL_CONFIG_JSON=previous;
    delete globalThis.__moderationCase;
  });
  for(const scenario of spec.cases) {
    const event={
      id:'conversation',condition:scenario.condition,headers:{},
      context:{aiQuotaRedis:{eval:async(_lua,_count,_actor,_service,cost)=>{assert.equal(cost,1);return 0}}},
      node:{req:Readable.from([Buffer.from(scenario.body)]),res:new EventEmitter()},
    };
    globalThis.__moderationCase=event;
    if(scenario.http===200) {
      assert.equal((await handler(event)).data.status,scenario.status,scenario.id);
    } else await assert.rejects(()=>handler(event),error=>error.statusCode===scenario.http,scenario.id);
    assert.equal(event.headers['Cache-Control'],'private, no-store');
    if(scenario.status==='generated') {
      assert.equal(event.selectedSkill, JSON.parse(scenario.body).skill_id ?? null);
      assert.equal(event.audit.skill_selection, event.selectedSkill ? 'explicit' : 'purpose-default');
      const input=JSON.parse(event.inference.messages[1].content);
      assert.deepEqual([...Object.keys(input)].sort(),['content','locale','rules','target_type']);
      assert.equal(input.content,spec.text);
      assert.deepEqual(input.rules.map(rule=>rule.id),[1,2,3,4]);
      assert.equal(event.inference.responseSchema.type,'object');
      assert.equal(event.inference.responseSchema.properties.rule_ids.minItems, 1);
      assert.equal(event.inference.responseSchema.properties.rule_ids.maxItems, 4);
      assert.equal(event.saved.expectedSequence,0);
      assert.equal(event.saved.modelVersion,'reviewer-build');
      assert.equal(event.saved.review.terms_generation,9);
      assert.equal(event.saved.review.version,1);
      assert.equal(event.inference.images,undefined);
      assert.equal(event.saved.review.skill_generation,4);
      assert.deepEqual(event.saved.review.advice,spec.goodAdvice);
      assert.match(event.saved.review.target.digest,/^[a-f0-9]{64}$/);
      assert(!Object.hasOwn(event.saved.review.target,'content'));
    } else assert.equal(event.saved,undefined);
    if(['anonymous','forbidden','wrong_purpose','disabled','terms_unavailable','empty','invalid'].includes(scenario.condition)) {
      assert.equal(event.inference,undefined,scenario.id);
    }
  }
});

test('vision moderates a public image-only post and stops before inference when the reference changes',async t=>{
  t.after(()=>delete globalThis.__moderationCase);
  const body=Buffer.from(JSON.stringify({target_type:'post',target_id:7,expected_sequence:0,locale:'zh'}));
  for (const condition of ['vision','vision-stale']) {
    const event={id:'conversation',condition,headers:{},
      context:{aiQuotaRedis:{eval:async()=>0}},
      node:{req:Readable.from([body]),res:new EventEmitter()}};
    globalThis.__moderationCase=event;
    if (condition==='vision-stale') {
      await assert.rejects(()=>handler(event),error=>error.statusCode===409);
      assert.equal(event.inference,undefined);
      assert.equal(event.saved,undefined);
    } else {
      assert.equal((await handler(event)).data.status,'generated');
      assert.deepEqual(event.inference.images,[{mime_type:'image/png',data:'iVBORw0KGgo='}]);
      assert.equal(event.saved.review.version,2);
      assert.equal(event.saved.review.image_sources[0].media_id,9);
      assert.match(event.saved.review.image_sources[0].version,/^[0-9a-f]{64}$/);
    }
  }
});
