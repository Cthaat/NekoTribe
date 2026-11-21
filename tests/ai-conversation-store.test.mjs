import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { Readable } from 'node:stream';

const root = fileURLToPath(new URL('../', import.meta.url));
const groupFixture = JSON.parse(await readFile(new URL('../specifications/scenarios/ai-group-draft.json', import.meta.url)));
const feedbackFixture = JSON.parse(await readFile(new URL('../specifications/scenarios/ai-moderation-feedback-http.json', import.meta.url)));
const feedbackSql = JSON.parse(await readFile(new URL('../specifications/requirements/ai-moderation-feedback.json', import.meta.url))).queries;
const stubs = {
  'oracledb': `export default { OUT_FORMAT_OBJECT: 4002, STRING: { num: 2001 } };`,
  '~/server/utils/v2': `
    export const v2Auth=e=>{if(!e.userId)throw Object.assign(Error('unauthorized'),{statusCode:401});return {userId:e.userId}};
    export const v2BadRequest=m=>{throw Object.assign(Error('400:'+m),{statusCode:400})};
    export const v2Forbidden=m=>{throw Object.assign(Error('403:'+m),{statusCode:403})};
    export const v2NotFound=m=>{throw Object.assign(Error('404:'+m),{statusCode:404})};
    export const v2Conflict=m=>{throw Object.assign(Error('409:'+m),{statusCode:409})};
    export const v2ServerError=()=>{throw Error('500:internal')};
    export const v2String=v=>typeof v==='string'?v:'';
    export const v2Number=v=>Number(v)||0;
    export const v2DateString=v=>typeof v==='string'?v:null;
    export const v2Execute=async(c,sql,binds,autoCommit)=>c.insert(sql,binds,autoCommit);
    export const v2One=async(c,sql,binds)=>c.read(sql,binds);
    export const v2Rows=async(c,sql,binds)=>c.readGroup(sql,binds);
    export const v2Connection=async e=>e.connection;
    export const v2RouterParam=(e,k)=>e.params[k];
    export const v2Ok=data=>({data});`,
  '~/server/database/readiness': `export const requireFeatureSchema=async(c,feature)=>{c.checks.push(feature)};`,
  './skill-config-store': `export async function lockSkillRegistry(e,c){c.skillLocks=(c.skillLocks||0)+1;if(c.skillFail)throw Error('SKILL_CONFIG_UNAVAILABLE');return {generation:c.skillGeneration??1,registry:{select:async(scope)=>{c.selectedSkill=scope.skillId;if(c.skillDisabled)throw Error('SKILL_UNAVAILABLE');return {id:scope.skillId}}}}}`,
  './knowledge-source': `export async function hydrateKnowledgeSources(e,c,refs,opts){c.knowledgeChecks++;c.knowledgeOptions.push(opts);if(c.revokeKnowledgeAfterMessage && c.pendingMessage)return [];return (c.knowledgeRows??[]).filter(r=>refs.some(x=>x.kind===r.kind && x.id===r.id) && !(c.pendingMessage && c.revokeHistoryId===r.id))}`,
  './public-terms-authority': `export async function readTermsAuthority(e,c,raw,options){
    if(c.termsUnavailable) throw Error('TERMS_AUTHORITY_UNAVAILABLE');
    if(options?.lock) c.termsLockCount=(c.termsLockCount??0)+1;
    return {digest:'a'.repeat(64),generation:c.termsGeneration??10};
  }`,
  '~/server/services/v2/groups': `export const v2GroupPermission=async(c)=>{c.permissionChecks++;if(c.permissionError)throw Error('database failure');return c.allowed};`,
  '~/server/services/v2/moderation': `export const requireModerationAccess=async(e,c)=>{if(!c.moderator)throw Object.assign(Error('403:需要审核权限'),{statusCode:403})};`
};
const compiled = await build({
  stdin: { contents: `export {createConversation,readConversation,deleteConversation,listConversations,appendUserMessage,appendAssistantMessage,appendKnowledgeAssistantMessage,appendGroupDraft,appendModerationAdvice,listConversationMessages,listRecentConversationMessages} from './server/services/ai/conversation-store';export {default as feedbackRoute} from './server/api/v2/ai/conversations/[id]/messages/[message_id]/moderation-feedback.put';`, resolveDir: root, loader: 'ts' },
  alias:{'~':root}, bundle: true, write: false, platform: 'node', format: 'esm', plugins: [{ name: 'conversation-store-boundaries', setup(builder) {
    const routeStubs={...stubs,'~/server/utils/auth-entry-errors':'export const safeV2Action=fn=>fn();'};
    builder.onResolve({ filter: /.*/ }, args => { if (Object.hasOwn(routeStubs, args.path)) return { path: args.path, namespace: 'stub' }; });
    builder.onLoad({ filter: /.*/, namespace: 'stub' }, args => ({ contents: routeStubs[args.path], loader: 'js' }));
  }}]
});


const { createConversation, readConversation, deleteConversation, listConversations, appendUserMessage, appendAssistantMessage, appendKnowledgeAssistantMessage, appendGroupDraft, appendModerationAdvice, listConversationMessages, listRecentConversationMessages, feedbackRoute } = await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);
const safeStubs={...stubs,'~/server/utils/v2':stubs['~/server/utils/v2'].replace("export const v2Conflict=m=>{throw Object.assign(Error('409:'+m),{statusCode:409})};",`export const v2Conflict=m=>{throw createError({statusCode:409,message:m,data:{code:40901,message:m,data:null,meta:null}})};`).replace('export const v2Auth=',`import {createError} from 'h3'; export const v2Auth=`)};
const safeCompiled=await build({stdin:{contents:`export {appendAssistantMessage,appendKnowledgeAssistantMessage} from './server/services/ai/conversation-store';export {safeV2Action} from './server/utils/auth-entry-errors';`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'safe-boundaries',setup(builder){builder.onResolve({filter:/.*/},args=>Object.hasOwn(safeStubs,args.path)?{path:args.path,namespace:'stub'}:undefined);builder.onLoad({filter:/.*/,namespace:'stub'},args=>({contents:safeStubs[args.path],loader:'js',resolveDir:root}));}}]});
const safe=await import(`data:text/javascript;base64,${Buffer.from(safeCompiled.outputFiles[0].text).toString('base64')}`);
function database() {
  return { checks: [], permissionChecks: 0, knowledgeChecks:0, knowledgeOptions:[], allowed: true, moderator: true, saved: null, pending: null, messages: [], pendingMessage: null, commits: 0, rollbacks: 0,
    async insert(sql, binds, autoCommit) {
      if (/DELETE FROM n_ai_conversations/.test(sql)) {
        assert.equal(autoCommit, false);
        assert.equal(binds.owner_user_id, this.saved?.OWNER_USER_ID);
        assert.equal(binds.conversation_id, this.saved?.CONVERSATION_ID);
        this.pendingDelete = true;
        if (this.revokeAfterDelete) this.allowed = false;
        return 1;
      }
      if (/INSERT INTO n_ai_messages/.test(sql)) {
        assert.equal(autoCommit, false); this.pendingMessage = binds;
        if (this.revokeAfterMessage) this.allowed = false;
        if (this.changeHistoryAfterMessage) this.messages[0].content = 'changed concurrently';
        return 1;
      }
      if (/UPDATE n_ai_conversations/.test(sql)) return 1;
      assert.match(sql, /INSERT INTO n_ai_conversations/); assert.equal(autoCommit, false);
      this.pending = { CONVERSATION_ID: binds.conversation_id, OWNER_USER_ID: binds.owner_user_id, PURPOSE: binds.purpose, GROUP_ID: binds.group_id, TITLE: binds.title, CREATED_AT: 'created', UPDATED_AT: 'updated' };
      if (this.revokeAfterInsert) this.allowed = false;
      return 1;
    },
    async read(sql, binds) {
      if (sql === feedbackSql.schema) return null;
      if (/MAX\(sequence_no\)/i.test(sql)) return { NEXT_SEQUENCE: this.messages.length + 1 };
      if (/SELECT group_id FROM n_groups/.test(sql)) {
        assert.match(sql, /FOR UPDATE/);
        return {GROUP_ID:binds.group_id};
      }
      assert.match(sql, /owner_user_id=:owner_user_id/);
      if (this.expectLock) assert.match(sql, /FOR UPDATE/i);
      const row = this.pending ?? this.saved;
      return row && row.CONVERSATION_ID === binds.conversation_id && row.OWNER_USER_ID === binds.owner_user_id ? row : null;
    },
    async execute(sql, binds, options) {
      assert.match(sql, /owner_user_id\s*=\s*:owner_user_id/i);
      assert.match(sql, /ORDER BY m.sequence_no (ASC|DESC)/i);
      assert.deepEqual(options.fetchTypeHandler({name: 'CONTENT'}), {type: {num: 2001}});
      assert.equal(options.fetchTypeHandler({name: 'MODEL_ID'}), undefined);
      if (this.revokeDuringList) this.allowed = false;
      const messages=this.messages.filter(m => binds.before_sequence
        ? m.sequence_no < binds.before_sequence : m.sequence_no > binds.after_sequence);
      if (/ORDER BY m.sequence_no DESC/i.test(sql)) messages.reverse();
      const page = messages.slice(0, binds.row_limit);
      if (binds.before_sequence) {
        assert.match(sql, /m.sequence_no<:before_sequence/);
        assert.match(sql, /\) ORDER BY sequence_no ASC$/);
        page.reverse();
      }
      return { rows: page.map(m => ({
        MESSAGE_ID: m.message_id, CONVERSATION_ID: m.conversation_id, SEQUENCE_NO: m.sequence_no,
        ROLE: m.role, CONTENT: m.content, MODEL_ID: m.model_id, MODEL_VERSION: m.model_version, CONFIG_REVISION: m.config_revision, CREATED_AT: 'created'
      })) };
    },
    async commit() { this.commits++; if (this.failCommit) throw Error('private'); if (this.pendingDelete) {this.saved=null;this.messages=[];this.pendingDelete=false;} if (this.pending) this.saved = this.pending; this.pending = null; if (this.pendingMessage) this.messages.push(this.pendingMessage); this.pendingMessage = null; },
    async rollback() { this.rollbacks++; if (this.failRollback) throw Error('private rollback'); this.pendingDelete=false; this.pending = null; this.pendingMessage = null; }
  };
}

test('group draft validates the original public snapshot at commit and again on history read',async()=>{
  const db=database(),actor={userId:42};
  db.readGroup=async(sql,binds)=>{
    assert.match(sql,/JOIN n_group_members/);
    assert.equal(binds.actor_id,42);
    assert.equal(binds.group_id,7);
    assert.equal(binds.lookback_days,7);
    assert.equal(binds.window_end,groupFixture.evidence.window_end);
    if (db.privateGroup) return [];
    const [example]=groupFixture.evidence.examples;
    return [{WINDOW_START:groupFixture.evidence.window_start,WINDOW_END:groupFixture.evidence.window_end,
      POSTS_COUNT:1,COMMENTS_COUNT:0,KIND:example.kind,SOURCE_ID:example.source_id,POST_ID:example.post_id,
      EXCERPT:db.changeGroupAtCommit&&db.pendingMessage?'内容已被编辑':example.excerpt}];
  };
  const conversation=await createConversation(actor,db,{purpose:'group',group_id:7});
  const draft={version:1,kind:'weekly_report',window_end:groupFixture.evidence.window_end,
    source_digest:groupFixture.digest,example_count:1,skill_generation:1,draft:'基于公开资料生成的草稿'};
  const input={draft,expectedSequence:0,modelId:'profile-a',configRevision:1};
  db.changeGroupAtCommit=true;
  await assert.rejects(()=>appendGroupDraft(actor,db,conversation.conversation_id,input),/409:/);
  assert.equal(db.messages.length,0);
  assert.equal(db.rollbacks,1);
  db.changeGroupAtCommit=false;
  db.revokeAfterMessage=true;
  await assert.rejects(()=>appendGroupDraft(actor,db,conversation.conversation_id,input),/403:/);
  assert.equal(db.messages.length,0);
  db.revokeAfterMessage=false;
  db.allowed=true;
  const saved=await appendGroupDraft(actor,db,conversation.conversation_id,input);
  assert.equal(saved.sequence_no,1);
  assert.equal(db.selectedSkill,'group-brief');
  await assert.rejects(()=>appendGroupDraft(actor,db,conversation.conversation_id,input),/409:/);
  const [current]=await listConversationMessages(actor,db,conversation.conversation_id,0,20);
  assert.equal(current.content,draft.draft);
  assert.deepEqual(current.group_sources,[{kind:'post',source_id:10,post_id:10}]);
  db.privateGroup=true;
  const [hidden]=await listConversationMessages(actor,db,conversation.conversation_id,0,20);
  assert.equal(hidden.content,'资料已变更，历史草稿不可用。');
  assert.deepEqual(hidden.group_sources,[]);
});

test('moderation advice rechecks source and rules at commit and redacts historical results on revision change',async()=>{
  const db=database(),actor={userId:42},content='Public moderation evidence';
  db.readGroup=async(sql,binds)=>{
    assert.match(sql,/p\.visibility='public'/);
    assert.deepEqual(binds,{actor_id:42,target_id:7});
    if(db.postHidden) return [];
    const text=db.editDuringCommit&&db.pendingMessage?'Edited public text':content;
    return [{POST_ID:7,GROUP_ID:null,CONTENT:text,TEXT_LENGTH:text.length}];
  };
  const conversation=await createConversation(actor,db,{purpose:'moderation'});
  const hash=createHash('sha256');
  for(const field of ['moderation-target-v1','post','7','7','',content]) hash.update(`${Buffer.byteLength(field)}:${field}`);
  const input={expectedSequence:0,modelId:'reviewer',configRevision:5,signal:new AbortController().signal,review:{
    version:1,target:{target_type:'post',target_id:7,post_id:7,group_id:null,digest:hash.digest('hex')},
    locale:'zh',terms_digest:'a'.repeat(64),terms_generation:10,skill_generation:1,
    advice:{risk:'harassment',reason:'Human review required',recommendation:'human_review',rule_ids:[3]},
  }};
  db.editDuringCommit=true;
  await assert.rejects(()=>appendModerationAdvice(actor,db,conversation.conversation_id,input),/409:/);
  assert.equal(db.messages.length,0);
  assert.equal(db.rollbacks,1);
  db.editDuringCommit=false;
  await appendModerationAdvice(actor,db,conversation.conversation_id,input);
  assert.equal(db.termsLockCount,2);
  assert.equal(db.selectedSkill,'moderation-advice');
  const history=async()=> (await listConversationMessages(actor,db,conversation.conversation_id,0,20))[0];
  assert.equal((await history()).moderation_advice.rules[0].id,3);
  db.postHidden=true;
  assert.equal((await history()).moderation_advice,null);
  db.postHidden=false;
  db.termsGeneration=11;
  assert.equal((await history()).moderation_advice,null);
  assert.doesNotMatch((await history()).content,/Human review required/);
});

test('moderation feedback shares request cases, serializes writes and reads only visible ratings',async t=>{
  const {conversationId, messageId} = feedbackFixture;
  const text = 'Public moderation evidence';
  const hash = createHash('sha256');
  for (const field of ['moderation-target-v1','post','7','7','',text]) hash.update(`${Buffer.byteLength(field)}:${field}`);
  const advice = JSON.stringify({
    version:1,target:{target_type:'post',target_id:7,post_id:7,group_id:null,digest:hash.digest('hex')},
    locale:'zh',terms_digest:'a'.repeat(64),terms_generation:10,skill_generation:1,
    advice:{risk:'harassment',reason:'Human review required',recommendation:'human_review',rule_ids:[3]},
  });
  for (const scenario of feedbackFixture.cases) await t.test(scenario.id,async()=>{
    const db = database(), condition= scenario.condition;
    const {read,execute,insert,commit,rollback}=db;
    db.saved = {CONVERSATION_ID:conversationId,OWNER_USER_ID:42,PURPOSE:'moderation',GROUP_ID:null,TITLE:null};
    db.messages = [{conversation_id:conversationId,message_id:messageId,sequence_no:1,role:'assistant',content:advice}];
    db.moderator = condition !== 'forbidden';
    db.rating = condition === 'replay' ? scenario.rating : undefined;
    db.schema = condition !== 'old_schema';
    db.locked = false;
    db.writeAttempts = 0;
    db.closed = 0;
    db.close = async () => { db.closed++; };
    db.read = async function(sql,binds) {
      if (sql === feedbackSql.schema) return this.schema ? {TABLE_NAME:'N_AI_MODERATION_FEEDBACK'} : null;
      if (sql === feedbackSql.lock) {
        assert.deepEqual(binds,{conversation_id:conversationId,owner_user_id:42});
        this.locked = condition !== 'not_owner';
        return this.locked ? {CONVERSATION_ID:conversationId} : null;
      }
      if (sql === feedbackSql.read) {
        assert.deepEqual(binds,{message_id:messageId});
        return this.rating ? {RATING:this.rating} : null;
      }
      return read.call(this,sql,binds);
    };
    db.execute = async function(sql,binds,options) {
      if (sql === feedbackSql.message) {
        assert(this.locked);
        assert.deepEqual(binds,{conversation_id:conversationId,message_id:messageId});
        assert(options.fetchTypeHandler({name:'CONTENT'}));
        return {rows:condition==='not_message'?[]:[{CONTENT:advice}]};
      }
      return execute.call(this,sql,binds,options);
    };
    db.insert = async function(sql,binds,autoCommit) {
      if (sql === feedbackSql.save) {
        assert(this.locked);
        assert.equal(autoCommit,false);
        assert.deepEqual(binds,{message_id:messageId,rating:scenario.rating ?? 'helpful'});
        this.writeAttempts++;
        if (this.rating === binds.rating) return 0;
        this.pendingRating=binds.rating;
        return 1;
      }
      return insert.call(this,sql,binds,autoCommit);
    };
    db.readGroup = async (sql,binds) => {
      assert.match(sql,/n_posts/);
      assert.deepEqual(binds,{actor_id:42,target_id:7});
      if (condition==='redacted' || db.hidden || (condition==='changed' && db.pendingRating)) return [];
      return [{CONTENT:text,TEXT_LENGTH:text.length,POST_ID:7,GROUP_ID:null}];
    };
    db.commit = async function() {
      await commit.call(this);
      this.rating=this.pendingRating ?? this.rating;
      this.pendingRating=undefined;
    };
    db.rollback = async function() {
      await rollback.call(this);
      this.pendingRating=undefined;
    };
    const headers = new Map();
    const event = {
      userId:condition==='anonymous'?null:42,connection:db,
      params:{id:conversationId,message_id:condition==='invalid_id'?'invalid':messageId},
      node:{req:Readable.from([Buffer.from(scenario.body)]),res:{setHeader:(k,v)=>headers.set(k,v)}},
    };
    if (scenario.http === 200) {
      assert.deepEqual((await feedbackRoute(event)).data,{message_id:messageId,rating:scenario.rating});
      assert.equal(db.rating,scenario.rating);
      assert.equal(db.commits,1);
      assert.equal(db.writeAttempts,1);
      assert.equal(db.closed,1);
      const history = async () => (await listConversationMessages(event,db,conversationId,0,20))[0];
      assert.equal((await history()).moderation_feedback,scenario.rating);
      db.schema=false;
      let prior=await history();
      assert.equal(prior.moderation_advice.reason,'Human review required');
      assert(!Object.hasOwn(prior,'moderation_feedback'));
      db.schema=true;
      db.hidden=true;
      prior=await history();
      assert.equal(prior.moderation_advice,null);
      assert(!Object.hasOwn(prior,'moderation_feedback'));
    } else {
      await assert.rejects(()=>feedbackRoute(event),error=>error.statusCode===scenario.http);
      assert.equal(db.rating,undefined);
      assert.equal(db.commits,0);
      assert.equal(db.writeAttempts,condition==='changed'?1:0);
      if (condition==='changed') assert.equal(db.rollbacks,1);
      if (['anonymous','invalid','invalid_id'].includes(condition)) assert.equal(db.closed,0);
    }
    assert.equal(headers.get('Cache-Control'),'private, no-store');
  });
});

test('knowledge answer requires an enabled, unchanged skill under transaction lock',async()=>{
 const db=database(),actor={userId:42},ref={kind:'post',id:1,version:'a'.repeat(64)};
 db.knowledgeRows=[{...ref,post_id:1,content:'public'}];const c=await createConversation(actor,db,{purpose:'knowledge'});await appendUserMessage(actor,db,c.conversation_id,'question');
 const input={answer:'answer',sources:[ref],expectedSequence:1,modelId:'p',configRevision:1,skillGeneration:1};
 db.skillGeneration=2;await assert.rejects(()=>appendKnowledgeAssistantMessage(actor,db,c.conversation_id,input));assert.equal(db.messages.length,1);assert.equal(db.rollbacks,1);
 db.skillGeneration=1;db.skillDisabled=true;await assert.rejects(()=>appendKnowledgeAssistantMessage(actor,db,c.conversation_id,input));assert.equal(db.messages.length,1);
 db.skillDisabled=false;await appendKnowledgeAssistantMessage(actor,db,c.conversation_id,input);assert.equal(db.messages.length,2);assert.equal(db.skillLocks,3);
});
test('writing answer locks and rejects a changed or disabled writing skill',async()=>{
 const db=database(),actor={userId:42};const c=await createConversation(actor,db,{purpose:'writing'});await appendUserMessage(actor,db,c.conversation_id,'question');
 const input={content:'draft',expectedSequence:1,modelId:'p',configRevision:1,skillGeneration:1};
 db.skillGeneration=2;await assert.rejects(()=>appendAssistantMessage(actor,db,c.conversation_id,input));assert.equal(db.messages.length,1);
 db.skillGeneration=1;db.skillDisabled=true;await assert.rejects(()=>appendAssistantMessage(actor,db,c.conversation_id,input));assert.equal(db.messages.length,1);
 db.skillDisabled=false;await appendAssistantMessage(actor,db,c.conversation_id,input);assert.equal(db.messages.length,2);assert.equal(db.skillLocks,3);assert.equal(db.selectedSkill,'writing-draft');
});
test('changed skill configuration survives the real public error sanitizer as 409',async()=>{
 for(const purpose of ['writing','knowledge']) {
  const db=database(),actor={userId:42};const c=await createConversation(actor,db,{purpose});await appendUserMessage(actor,db,c.conversation_id,'question');db.skillGeneration=2;
  const metadata={expectedSequence:1,modelId:'p',configRevision:1,skillGeneration:1};
  const action=purpose==='writing'
   ?()=>safe.appendAssistantMessage(actor,db,c.conversation_id,{content:'draft',...metadata})
   :()=>safe.appendKnowledgeAssistantMessage(actor,db,c.conversation_id,{answer:'answer',sources:[{kind:'post',id:1,version:'a'.repeat(64)}],...metadata});
  await assert.rejects(()=>safe.safeV2Action(action),error=>error.statusCode===409 && error.data.code===40901 && error.data.message==='会话已变更，请重试');
  assert.equal(db.messages.length,1);assert.equal(db.rollbacks,1);
 }
});

test('cancelled knowledge and writing turns roll back the pending assistant message', async () => {
  for (const purpose of ['knowledge', 'writing']) {
    const db=database(), actor={userId:42};
    const source={kind:'post',id:1,version:'a'.repeat(64)};
    db.knowledgeRows=[{...source,post_id:1,content:'public'}];
    const conversation=await createConversation(actor,db,{purpose});
    const user=await appendUserMessage(actor,db,conversation.conversation_id,'question');
    const controller=new AbortController();
    const insert=db.insert;
    db.insert=async function(sql,...args) {
      const result=await insert.call(this,sql,...args);
      if (sql.includes('UPDATE n_ai_conversations')) controller.abort();
      return result;
    };
    const commits=db.commits;
    const common={expectedSequence:user.sequence_no,modelId:'profile',configRevision:1,skillGeneration:1,signal:controller.signal};
    const append=purpose==='knowledge'
      ? appendKnowledgeAssistantMessage(actor,db,conversation.conversation_id,{...common,answer:'answer',sources:[source]})
      : appendAssistantMessage(actor,db,conversation.conversation_id,{...common,content:'draft'});
    await assert.rejects(append, error=>error===controller.signal.reason);
    assert.equal(db.commits,commits);
    assert.equal(db.rollbacks,1);
    assert.equal(db.messages.length,1);
    assert.equal(db.pendingMessage,null);
  }
});

test('knowledge answer rejects changed selected history before insert or before commit',async()=>{
  for(const timing of ['before','during']) {
    const db=database(),actor={userId:42},ref={kind:'post',id:1,version:'a'.repeat(64)};
    db.knowledgeRows=[{...ref,post_id:1,content:'public'}];
    const c=await createConversation(actor,db,{purpose:'knowledge'});
    await appendUserMessage(actor,db,c.conversation_id,'original');
    const contextSnapshot=[{sequence_no:1,role:'user',content:'original'}];
    if(timing==='before') db.messages[0].content='changed concurrently';
    else db.changeHistoryAfterMessage=true;
    await assert.rejects(()=>appendKnowledgeAssistantMessage(actor,db,c.conversation_id,{answer:'answer',sources:[ref],contextSources:[],contextSnapshot,expectedSequence:1,modelId:'p',configRevision:1,skillGeneration:1}),/409:/);
    assert.equal(db.messages.length,1);assert.equal(db.rollbacks,1);
  }
});

test('knowledge answer validates and accepts the exact selected historical messages and citations',async()=>{
  const db=database(),actor={userId:42},old={kind:'post',id:1,version:'a'.repeat(64)},current={kind:'post',id:2,version:'b'.repeat(64)};
  db.knowledgeRows=[{...old,post_id:1,content:'old'},{...current,post_id:2,content:'new'}];
  const c=await createConversation(actor,db,{purpose:'knowledge'});
  await appendUserMessage(actor,db,c.conversation_id,'first');
  await appendKnowledgeAssistantMessage(actor,db,c.conversation_id,{answer:'old answer',sources:[old],expectedSequence:1,modelId:'p',configRevision:1,skillGeneration:1});
  await appendUserMessage(actor,db,c.conversation_id,'follow up');
  const snapshot=[{sequence_no:2,role:'assistant',content:'old answer',citations:[{...old,post_id:1}]},{sequence_no:3,role:'user',content:'follow up'}];
  const input={answer:'new answer',sources:[current,old],contextSources:[old],contextSnapshot:snapshot,expectedSequence:3,modelId:'p',configRevision:1,skillGeneration:1};
  await assert.rejects(()=>appendKnowledgeAssistantMessage(actor,db,c.conversation_id,{...input,contextSources:[]}),/400:/);
  await appendKnowledgeAssistantMessage(actor,db,c.conversation_id,input);
  assert.equal(db.messages.length,4);assert.equal(db.messages[3].sequence_no,4);
});
test('mixed terms history survives transaction guards without a fabricated post ID',async()=>{
 const db=database(),actor={userId:42},terms={kind:'terms',id:3,version:'b'.repeat(64)},post={kind:'post',id:1,version:'a'.repeat(64)};
 db.knowledgeRows=[{...terms,content:'规则'},{...post,post_id:1,content:'帖子'}];
 const c=await createConversation(actor,db,{purpose:'knowledge'});await appendUserMessage(actor,db,c.conversation_id,'first');
 await appendKnowledgeAssistantMessage(actor,db,c.conversation_id,{answer:'old',sources:[terms],expectedSequence:1,modelId:'p',configRevision:1,skillGeneration:1});
 await appendUserMessage(actor,db,c.conversation_id,'next');
 const snapshot=[{sequence_no:2,role:'assistant',content:'old',citations:[terms]},{sequence_no:3,role:'user',content:'next'}];
 const input={answer:'new',sources:[post,terms],contextSources:[terms],contextSnapshot:snapshot,expectedSequence:3,modelId:'p',configRevision:1,skillGeneration:1};
 const forged=[{...snapshot[0],citations:[{...terms,post_id:1}]},snapshot[1]];
 await assert.rejects(()=>appendKnowledgeAssistantMessage(actor,db,c.conversation_id,{...input,contextSnapshot:forged}),/400:/);
 await appendKnowledgeAssistantMessage(actor,db,c.conversation_id,input);
 assert(db.knowledgeOptions.some(option=>option?.lockTerms===true));
 assert.deepEqual((await listConversationMessages(actor,db,c.conversation_id,0,20))[3].citations,[{...post,post_id:1},terms]);
});

test('knowledge assistant stores versioned references and rechecks history visibility',async()=>{
  const db=database(),actor={userId:42},ref={kind:'post',id:1,version:'a'.repeat(64)};
  db.knowledgeRows=[{...ref,post_id:1,content:'public'}];
  const c=await createConversation(actor,db,{purpose:'knowledge'});
  await appendUserMessage(actor,db,c.conversation_id,'question');
  await appendKnowledgeAssistantMessage(actor,db,c.conversation_id,{answer:'answer',sources:[ref],expectedSequence:1,modelId:'profile-a',configRevision:1,skillGeneration:1});
  assert.equal(db.knowledgeChecks,2);assert.deepEqual(JSON.parse(db.messages[1].content),{version:1,answer:'answer',sources:[ref]});
  const history=await listConversationMessages(actor,db,c.conversation_id,0,20);
  assert.equal(history[1].content,'answer');assert.deepEqual(history[1].citations,[{...ref,post_id:1}]);
  db.knowledgeRows=[];
  await appendUserMessage(actor,db,c.conversation_id,'new question');
  const redacted=await listConversationMessages(actor,db,c.conversation_id,0,20);
  assert.deepEqual(redacted.map(row=>[row.sequence_no,row.content]),[[1,'question'],[2,'公开资料已变更，历史回答不可用。'],[3,'new question']]);
  assert.equal(redacted[1].citations,undefined);
  const recent=await listRecentConversationMessages(actor,db,c.conversation_id);
  assert.deepEqual(recent.map(row=>[row.sequence_no,row.content]),[[3,'new question']]);
});
test('knowledge assistant rolls back when sources change before commit and rejects unreferenced assistant writes',async()=>{
  const db=database(),actor={userId:42},ref={kind:'post',id:1,version:'a'.repeat(64)};
  db.knowledgeRows=[{...ref,post_id:1,content:'public'}];
  const c=await createConversation(actor,db,{purpose:'knowledge'});await appendUserMessage(actor,db,c.conversation_id,'question');
  await assert.rejects(()=>appendAssistantMessage(actor,db,c.conversation_id,{content:'unsafe',expectedSequence:1,modelId:'p',configRevision:1,skillGeneration:1}),/409:/);
  db.revokeKnowledgeAfterMessage=true;
  await assert.rejects(()=>appendKnowledgeAssistantMessage(actor,db,c.conversation_id,{answer:'answer',sources:[ref],expectedSequence:1,modelId:'p',configRevision:1,skillGeneration:1}),/500:/);
  assert.equal(db.messages.length,1);assert.equal(db.rollbacks,2);
});
test('selected historical sources are revalidated in the answer transaction',async()=>{
 const db=database(),actor={userId:42},ref={kind:'post',id:1,version:'a'.repeat(64)};
 db.knowledgeRows=[{...ref,post_id:1,content:'public'}];const c=await createConversation(actor,db,{purpose:'knowledge'});await appendUserMessage(actor,db,c.conversation_id,'question');
 await appendKnowledgeAssistantMessage(actor,db,c.conversation_id,{answer:'answer',sources:[ref],contextSources:[ref],expectedSequence:1,modelId:'p',configRevision:1,skillGeneration:1});
 assert.equal(db.knowledgeChecks,4);assert.deepEqual(JSON.parse(db.messages[1].content),{version:1,answer:'answer',sources:[ref]});
});
test('revoked historical source rolls back even when new answer sources remain visible',async()=>{
 const db=database(),actor={userId:42},newRef={kind:'post',id:1,version:'a'.repeat(64)},oldRef={kind:'comment',id:2,version:'b'.repeat(64)};
 db.knowledgeRows=[{...newRef,post_id:1,content:'new'},{...oldRef,post_id:1,content:'old'}];const c=await createConversation(actor,db,{purpose:'knowledge'});await appendUserMessage(actor,db,c.conversation_id,'question');
 db.revokeHistoryId=2;
 await assert.rejects(()=>appendKnowledgeAssistantMessage(actor,db,c.conversation_id,{answer:'answer',sources:[newRef],contextSources:[oldRef],expectedSequence:1,modelId:'p',configRevision:1,skillGeneration:1}),/500:/);
 assert.equal(db.messages.length,1);assert.equal(db.rollbacks,1);
});
test('legacy unreferenced knowledge history returns a placeholder without revealing the answer',async()=>{
  const db=database(),actor={userId:42};const c=await createConversation(actor,db,{purpose:'knowledge'});
  await appendUserMessage(actor,db,c.conversation_id,'question');
  db.messages.push({message_id:'old',conversation_id:c.conversation_id,sequence_no:2,role:'assistant',content:'old unreferenced answer'});
  const history=await listConversationMessages(actor,db,c.conversation_id,0,20);
  assert.equal(history[1].content,'公开资料已变更，历史回答不可用。');
  assert.deepEqual(await listRecentConversationMessages(actor,db,c.conversation_id),[]);
  await assert.rejects(()=>listConversationMessages({userId:9},db,c.conversation_id,0,20),/404:/);
  db.messages[1].role='tool';
  await assert.rejects(()=>listConversationMessages(actor,db,c.conversation_id,0,20),/500:/);
});

test('conversation listing uses a bounded owner-scoped cursor and rechecks revoked access',async()=>{
  const db=database(),actor={userId:42};
  const rows=[
    {CONVERSATION_ID:'0f9da41c-7296-4f51-91f4-141f5c6e3c01',OWNER_USER_ID:42,PURPOSE:'writing',GROUP_ID:null,TITLE:'draft'},
    {CONVERSATION_ID:'1f9da41c-7296-4f51-91f4-141f5c6e3c01',OWNER_USER_ID:42,PURPOSE:'group',GROUP_ID:7,TITLE:'hidden'},
    {CONVERSATION_ID:'2f9da41c-7296-4f51-91f4-141f5c6e3c01',OWNER_USER_ID:42,PURPOSE:'knowledge',GROUP_ID:null,TITLE:'questions'},
  ];
  db.allowed=false; db.moderator=false;
  db.execute=async(sql,binds)=>{
    assert.match(sql,/owner_user_id\s*=\s*:owner_user_id/i);
    assert.match(sql,/fn_has_group_permission/i);
    assert.equal(binds.owner_user_id,42);assert.equal(binds.moderation_allowed,0);assert.equal(binds.row_limit,3);
    return {rows};
  };
  const result=await listConversations(actor,db,'',2);
  assert.deepEqual(result.items.map(x=>x.title),['draft','questions']);
  assert.equal(result.next_cursor,rows[2].CONVERSATION_ID);
  db.execute=async(sql,binds)=>{
    assert.match(sql,/c\.purpose\s*=\s*:purpose/);
    assert.equal(binds.purpose,'knowledge');
    return {rows:rows.filter(row=>row.PURPOSE===binds.purpose).slice(0,binds.row_limit)};
  };
  assert.deepEqual((await listConversations(actor,db,'',1,'knowledge')).items.map(x=>x.title),['questions']);
  await assert.rejects(()=>listConversations(actor,db,'bad',2),/400:/);
});

test('moderation history filters the exact target and respects current roles',async()=>{
  const db=database(), actor={userId:42};
  const target='moderation:post:17';
  const rows=[
    {CONVERSATION_ID:'0f9da41c-7296-4f51-91f4-141f5c6e3c01',OWNER_USER_ID:42,PURPOSE:'moderation',GROUP_ID:null,TITLE:'moderation:post:18'},
    {CONVERSATION_ID:'1f9da41c-7296-4f51-91f4-141f5c6e3c01',OWNER_USER_ID:42,PURPOSE:'moderation',GROUP_ID:null,TITLE:target},
  ];
  db.execute=async(sql,binds)=>{
    assert.match(sql,/c\.title=:target_title AND c\.group_id IS NULL/);
    assert.equal(binds.target_title,target);
    return {rows: rows.filter(row=>binds.moderation_allowed && row.TITLE===binds.target_title)};
  };
  const allowed=await listConversations(actor,db,'',1,'moderation',undefined,target);
  assert.deepEqual(allowed.items.map(item=>item.title),[target]);
  assert.equal(allowed.next_cursor,null);
  db.moderator=false;
  assert.deepEqual(await listConversations(actor,db,'',1,'moderation',undefined,target),{items:[],next_cursor:null});
});

test('conversation listing fails closed when permission checks fail and does not leak hidden cursor IDs',async()=>{
  const db=database(),actor={userId:42};
  const id='0f9da41c-7296-4f51-91f4-141f5c6e3c01';
  db.permissionError=true;
  db.execute=async()=>({rows:[{CONVERSATION_ID:id,OWNER_USER_ID:42,PURPOSE:'group',GROUP_ID:7,TITLE:'private'}]});
  await assert.rejects(()=>listConversations(actor,db,'',10),/database failure/);
  db.permissionError=false;db.allowed=false;
  const page=await listConversations(actor,db,'',10);
  assert.deepEqual(page,{items:[],next_cursor:null});
});

test('conversation listing advances with the last visible ID rather than inaccessible rows',async()=>{
  const db=database(),actor={userId:42};
  const ids=['0f9da41c-7296-4f51-91f4-141f5c6e3c01','1f9da41c-7296-4f51-91f4-141f5c6e3c01','2f9da41c-7296-4f51-91f4-141f5c6e3c01'];
  db.allowed=false;
  db.execute=async(sql,binds)=>({rows:ids.map((id,i)=>({CONVERSATION_ID:id,OWNER_USER_ID:42,PURPOSE:i===1?'group':'writing',GROUP_ID:i===1?7:null,TITLE:String(i)})).filter(row=>row.CONVERSATION_ID>(binds.after_id??''))});
  const first=await listConversations(actor,db,'',1);
  assert.deepEqual(first.items.map(x=>x.title),['0']);assert.equal(first.next_cursor,ids[0]);
  const second=await listConversations(actor,db,first.next_cursor,1);
  assert.deepEqual(second.items.map(x=>x.title),['2']);assert.equal(second.next_cursor,ids[2]);
});

test('delete locks owned conversation and removes its messages only after commit', async () => {
  const db=database(),actor={userId:42};
  const c=await createConversation(actor,db,{purpose:'writing'});
  await appendUserMessage(actor,db,c.conversation_id,'private');
  db.expectLock=true;
  await assert.rejects(()=>deleteConversation({userId:9},db,c.conversation_id),/404:/);
  assert.equal(db.messages.length,1);
  await deleteConversation(actor,db,c.conversation_id);
  assert.equal(db.saved,null); assert.deepEqual(db.messages,[]);
});

test('delete rolls back if group permission is revoked before commit',async()=>{
  const db=database(),actor={userId:42};
  const c=await createConversation(actor,db,{purpose:'group',group_id:7});
  db.revokeAfterDelete=true;
  await assert.rejects(()=>deleteConversation(actor,db,c.conversation_id),/403:/);
  assert.equal(db.saved.CONVERSATION_ID,c.conversation_id); assert.equal(db.rollbacks,1);
});

test('delete rejects malformed identifiers and never assumes an uncertain commit rolled back',async()=>{
  const db=database(),actor={userId:42};
  const c=await createConversation(actor,db,{purpose:'writing'});
  const checks=db.checks.length;
  await assert.rejects(()=>deleteConversation(actor,db,'invalid'),/404:/);
  assert.equal(db.checks.length,checks);
  db.failCommit=true;
  await assert.rejects(()=>deleteConversation(actor,db,c.conversation_id),error=>error.message==='500:internal');
  assert.equal(db.rollbacks,0);
});

test('message history paginates by sequence and hides other users conversations', async () => {
  const db = database();
  const conversation = await createConversation({ userId: 42 }, db, { purpose: 'knowledge' });
  await appendUserMessage({ userId: 42 }, db, conversation.conversation_id, 'first');
  await appendUserMessage({ userId: 42 }, db, conversation.conversation_id, 'second');
  const page = await listConversationMessages({ userId: 42 }, db, conversation.conversation_id, 1, 10);
  assert.deepEqual(page.map(m => [m.sequence_no, m.content]), [[2, 'second']]);
  await assert.rejects(() => listConversationMessages({ userId: 9 }, db, conversation.conversation_id, 0, 10), /404:/);
  await assert.rejects(() => listConversationMessages({ userId: 42 }, db, conversation.conversation_id, -1, 10), /400:/);
  await assert.rejects(() => listConversationMessages({ userId: 42 }, db, conversation.conversation_id, 0, 51), /400:/);
});

test('recent conversation history uses newest messages in chronological order',async()=>{
  const db=database(),actor={userId:42};
  const conversation=await createConversation(actor,db,{purpose:'writing'});
  for(let i=0;i<52;i++)await appendUserMessage(actor,db,conversation.conversation_id,String(i));
  const messages=await listRecentConversationMessages(actor,db,conversation.conversation_id);
  assert.equal(messages.length,50);assert.equal(messages[0].sequence_no,3);assert.equal(messages.at(-1).sequence_no,52);
  const latest = await listConversationMessages(actor,db,conversation.conversation_id,0,2,10000000000);
  assert.deepEqual(latest.map(m=>m.sequence_no),[51,52]);
  const older = await listConversationMessages(actor,db,conversation.conversation_id,0,2,latest[0].sequence_no);
  assert.deepEqual(older.map(m=>m.sequence_no),[49,50]);
});

test('message history is not returned after group permission is revoked during retrieval', async () => {
  const db = database();
  const conversation = await createConversation({ userId: 42 }, db, { purpose: 'group', group_id: 7 });
  db.revokeDuringList = true;
  await assert.rejects(() => listConversationMessages({ userId: 42 }, db, conversation.conversation_id, 0, 10), /403:/);
});

test('append locks owned conversation and persists sequential user messages', async () => {
  const db = database();
  const conversation = await createConversation({ userId: 42 }, db, { purpose: 'knowledge' });
  db.expectLock = true;
  const first = await appendUserMessage({ userId: 42 }, db, conversation.conversation_id, 'hello');
  const second = await appendUserMessage({ userId: 42 }, db, conversation.conversation_id, 'world');
  assert.deepEqual([first.sequence_no, second.sequence_no], [1, 2]);
  assert.deepEqual(db.messages.map(m => m.content), ['hello', 'world']);
  await assert.rejects(() => appendUserMessage({ userId: 9 }, db, conversation.conversation_id, 'private'), /404:会话不存在/);
  assert.equal(db.messages.length, 2);
});

test('append rolls back when a group administrator loses access before commit', async () => {
  const db = database();
  const conversation = await createConversation({ userId: 42 }, db, { purpose: 'group', group_id: 7 });
  db.revokeAfterMessage = true;
  await assert.rejects(() => appendUserMessage({ userId: 42 }, db, conversation.conversation_id, 'hello'), /403:需要群管理员权限/);
  assert.equal(db.messages.length, 0);
  assert.equal(db.rollbacks, 1);
});

test('append rejects empty or excessive messages', async () => {
  const db = database();
  const conversation = await createConversation({ userId: 42 }, db, { purpose: 'knowledge' });
  await assert.rejects(() => appendUserMessage({ userId: 42 }, db, conversation.conversation_id, ''), /400:/);
  await assert.rejects(() => appendUserMessage({ userId: 42 }, db, conversation.conversation_id, 'x'.repeat(65537)), /400:/);
  await assert.rejects(() => appendUserMessage({ userId: 42 }, db, conversation.conversation_id, '猫'.repeat(21846)), /400:/);
  assert.equal(db.messages.length, 0);
});

test('append reports an uncertain commit as failure without claiming rollback', async () => {
  const db = database();
  const conversation = await createConversation({ userId: 42 }, db, { purpose: 'knowledge' });
  db.failCommit = true;
  await assert.rejects(() => appendUserMessage({ userId: 42 }, db, conversation.conversation_id, 'hello'), error => error.message === '500:internal');
  assert.equal(db.rollbacks, 0);
});

test('assistant message records model revision and rejects stale conversation history', async () => {
  const db=database(), actor={userId:42};
  const conversation=await createConversation(actor,db,{purpose:'writing'});
  const user=await appendUserMessage(actor,db,conversation.conversation_id,'draft');
  const answer=await appendAssistantMessage(actor,db,conversation.conversation_id,{content:'result',expectedSequence:user.sequence_no,modelId:'profile-a',modelVersion:'2026.11+q4',configRevision:12,skillGeneration:1});
  assert.equal(answer.sequence_no,2);assert.equal(answer.role,'assistant');
  assert.equal(db.messages[1].model_id,'profile-a');assert.equal(db.messages[1].config_revision,12);
  assert.equal(db.messages[0].model_version,null);
  assert.equal(db.messages[1].model_version,'2026.11+q4');
  const history=await listConversationMessages(actor,db,conversation.conversation_id,1,10);
  assert.equal(history[0].role,'assistant');assert.equal(history[0].model_id,'profile-a');assert.equal(history[0].config_revision,12);
  assert.equal(history[0].model_version,'2026.11+q4');
  await assert.rejects(()=>appendAssistantMessage(actor,db,conversation.conversation_id,{content:'stale',expectedSequence:1,modelId:'profile-a',configRevision:12,skillGeneration:1}),/409:/);
  assert.equal(db.messages.length,2);assert.equal(db.rollbacks,1);
});

test('assistant message rejects invalid metadata and unverified group drafts', async () => {
  const db=database(),actor={userId:42};
  const conversation=await createConversation(actor,db,{purpose:'group',group_id:7});
  const user=await appendUserMessage(actor,db,conversation.conversation_id,'draft');
  await assert.rejects(()=>appendAssistantMessage(actor,db,conversation.conversation_id,{content:'x',expectedSequence:user.sequence_no,modelId:'profile-a',configRevision:1000000000000000,skillGeneration:1}),/400:/);
  await assert.rejects(()=>appendAssistantMessage(actor,db,conversation.conversation_id,{content:'x',expectedSequence:user.sequence_no,modelId:'profile-a',configRevision:1,skillGeneration:1}),/409:/);
  assert.equal(db.messages.length,1);
});

test('create and read restrict ownership and never accept provider credentials', async () => {
  const db = database();
  const result = await createConversation({ userId: 42 }, db, { purpose: 'knowledge', title: '  hello  ' });
  assert.match(result.conversation_id, /^[0-9a-f-]{36}$/); assert.equal(result.title, 'hello'); assert.equal(db.commits, 1);
  assert.deepEqual(await readConversation({ userId: 42 }, db, result.conversation_id), result);
  await assert.rejects(() => readConversation({ userId: 9 }, db, result.conversation_id), /404:会话不存在/);
  await assert.rejects(() => createConversation({ userId: 42 }, db, { purpose: 'knowledge', api_key: 'secret' }), /400:会话参数错误/);
});

test('group permission is checked again before commit and on later reads', async () => {
  const db = database(); db.revokeAfterInsert = true;
  await assert.rejects(() => createConversation({ userId: 42 }, db, { purpose: 'group', group_id: 7 }), /403:需要群管理员权限/);
  assert.equal(db.permissionChecks, 2); assert.equal(db.commits, 0); assert.equal(db.rollbacks, 1); assert.equal(db.saved, null);
  db.allowed = true; db.revokeAfterInsert = false;
  const result = await createConversation({ userId: 42 }, db, { purpose: 'group', group_id: 7 });
  db.allowed = false;
  await assert.rejects(() => readConversation({ userId: 42 }, db, result.conversation_id), /403:需要群管理员权限/);
});

test('moderation permission and uncertain commit fail safely', async () => {
  const db = database(); db.moderator = false;
  await assert.rejects(() => createConversation({ userId: 42 }, db, { purpose: 'moderation' }), /403:需要审核权限/);
  assert.equal(db.pending, null);
  db.moderator = true; db.failCommit = true;
  await assert.rejects(() => createConversation({ userId: 42 }, db, { purpose: 'moderation' }), /500:internal/);
  assert.equal(db.commits, 1); assert.equal(db.rollbacks, 0);
});

test('rollback failure is safely reported without leaking driver details', async () => {
  const db = database(); db.revokeAfterInsert = true; db.failRollback = true;
  await assert.rejects(() => createConversation({ userId: 42 }, db, { purpose: 'group', group_id: 7 }), error => error.message === '500:internal');
  assert.equal(db.commits, 0); assert.equal(db.rollbacks, 1);
});
