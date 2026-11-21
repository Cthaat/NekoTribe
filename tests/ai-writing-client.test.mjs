import assert from 'node:assert/strict';
import { test } from 'node:test';
import { build, transform } from 'esbuild';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { discussionDraft, stageDiscussionDraft, takeDiscussionDraft } from '../app/utils/ai-discussion-draft.ts';

const root=fileURLToPath(new URL('../',import.meta.url));
const compiled=await build({stdin:{contents:`export * from './app/services/ai-writing-controller.ts'; export * from './app/utils/ai-post-draft.ts';`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm'});
const {aiMessageBytes,aiMessageContent,aiMessageMaxBytes,createWritingController,initialWritingState,stageAiPostDraft,takeAiPostDraft}=await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);

test('discussion prefill keeps only public post text and its visible comments within the budget', () => {
  const post = { id: 42, visibility: 'public', content: ' Main post ' };
  const comments = [{ postId: 9, content: 'wrong post' }, { postId: 42, content: ' first comment ' },
    ...Array.from({ length: 20 }, (_, i) => ({ postId: 42, content: `comment ${i}` }))];
  assert.equal(discussionDraft(post, comments).split('\n\n').length, 21);
  assert.match(discussionDraft(post, comments), /^Main post\n\nfirst comment/);
  assert.equal(discussionDraft(post, [{ postId: 42, content: '界'.repeat(6000) }]), 'Main post');
  assert.equal(discussionDraft({ ...post, visibility: 'followers' }, comments), '');
  const app = {};
  stageDiscussionDraft(app, 1, 'old');
  assert.equal(takeDiscussionDraft(app, 2), '');
  stageDiscussionDraft(app, 2, 'open only once');
  assert.equal(takeDiscussionDraft(app, 2), 'open only once');
  assert.equal(takeDiscussionDraft(app, 2), '');
});

test('group discussion rechecks visibility before preparing a writing draft', async () => {
  const page = readFileSync(new URL('../app/pages/groups/posts.vue', import.meta.url), 'utf8');
  const start = page.indexOf('const canSummarizeDiscussion');
  const end = page.indexOf('async function sendGroupComment', start);
  assert.ok(start >= 0 && end > start);
  const { code } = await transform(`
    export function fixture(getGroupPost, listGroupPostComments, discussionDraft, stageDiscussionDraft) {
      const app = {}, opened = [], reported = [];
      const router = {currentRoute:{value:{path:'/ai/writing'}},async push(path){opened.push(path)}};
      const authQueueFor = () => ({revision:1,isIdentityChanging:false});
      const currentCommentScope = () => () => true;
      const preferenceStore = {isLoggedIn:true};
      const summaryPending = {value:false};
      const commentPost = {value:{id:42,content:'old post',group:{id:7,privacy:'public',isActive:true}}};
      const comments = {value:[
        {id:1,postId:42,content:'old comment'},
        {id:2,postId:42,content:'deleted comment'},
        {id:3,postId:43,content:'wrong post'}
      ]};
      const commentRequest = 1, commentSort = {value:'newest'};
      const citedComment = {value:undefined};
      const computed = fn => ({get value(){return fn()}});
      const localePath = path => path, t = key => key, toast = {error: key => reported.push(key)};
      ${page.slice(start,end)}
      return {app,opened,reported,citedComment,summarizeGroupDiscussion};
    }
  `, {loader:'ts',format:'esm'});
  const { fixture } = await import(`data:text/javascript;base64,${Buffer.from(code).toString('base64')}`);
  let privacy = 'private';
  const view = fixture(async (groupId, postId) => {
    assert.deepEqual([groupId,postId],[7,42]);
    return {id:42,content:'current post',group:{privacy,isActive:true}};
  },async (...params) => {
    assert.deepEqual(params,[7,42,1,20,undefined,'newest']);
    return {comments:[
      {id:1,postId:42,content:'edited comment'},
      {id:1,postId:42,content:'duplicate'},
      {id:4,postId:42,content:'unseen comment'},
      {id:2,postId:43,content:'wrong post'}
    ]};
  },discussionDraft,stageDiscussionDraft);
  await view.summarizeGroupDiscussion();
  assert.deepEqual(view.opened,[]);
  assert.equal(takeDiscussionDraft(view.app,1),'');
  assert.deepEqual(view.reported,['groups.posts.summaryUnavailable']);
  privacy = 'public';
  await view.summarizeGroupDiscussion();
  assert.deepEqual(view.opened,['/ai/writing']);
  assert.equal(takeDiscussionDraft(view.app,1),'current post\n\nedited comment');
});

test('ordinary post summary transfers only refreshed public content', async () => {
  const page = readFileSync(new URL('../app/pages/tweet/[id].vue', import.meta.url), 'utf8');
  const start = page.indexOf('async function openDiscussionSummary(');
  const end = page.indexOf('function clearInteractions(', start);
  assert.ok(start >= 0 && end > start);
  const { code } = await transform(`
    export function fixture(v2GetPost, v2ListComments, discussionDraft, stageDiscussionDraft) {
      const app = {}, opened = [];
      const router = {currentRoute:{value:{path:'/ai/writing'}},async push(path){opened.push(path)}};
      const active = () => true, currentPage = () => active;
      const currentPostId = {value:42}, citedCommentId = {value:undefined};
      const preferenceStore = {isLoggedIn:true}, auth = {revision:1};
      const summaryPending = {value:false};
      const tweet = {value:{id:42,visibility:'public',content:'old post'}};
      const comments = {value:[{id:1,postId:42,content:'old comment'}]};
      const commentViewRevision = 1, tweetRevision = 1;
      const localePath = path => path, t = key => key, toast = {error(){}};
      ${page.slice(start,end)}
      return {app,opened,openDiscussionSummary};
    }
  `, {loader:'ts',format:'esm'});
  const { fixture } = await import(`data:text/javascript;base64,${Buffer.from(code).toString('base64')}`);
  let visibility = 'followers';
  const view = fixture(async () => ({id:42,visibility,content:'current post'}),
    async (id, query) => {
      assert.equal(id,42);
      assert.deepEqual(query,{page:1,pageSize:20,sort:'oldest'});
      return {items:[{id:1,postId:42,content:'edited comment'},{id:2,postId:42,content:'unseen comment'}]};
    },discussionDraft,stageDiscussionDraft);
  await view.openDiscussionSummary();
  assert.deepEqual(view.opened,[]);
  assert.equal(takeDiscussionDraft(view.app,1),'');
  visibility = 'public';
  await view.openDiscussionSummary();
  assert.deepEqual(view.opened,['/ai/writing']);
  assert.equal(takeDiscussionDraft(view.app,1),'current post\n\nedited comment');
});

test('a staged post draft is consumed once by the same app and session', () => {
  const app = {};
  const cancel = stageAiPostDraft(app, 1, 'previous');
  stageAiPostDraft(app, 1, '  keep the draft text  ');
  cancel();
  assert.equal(takeAiPostDraft({}, 1), '');
  assert.equal(takeAiPostDraft(app, 1), '  keep the draft text  ');
  assert.equal(takeAiPostDraft(app, 1), '');
  stageAiPostDraft(app, 1, 'expired');
  assert.equal(takeAiPostDraft(app, 2), '');
  assert.equal(takeAiPostDraft(app, 1), '');
  stageAiPostDraft(app, 2, 'cancelled')();
  assert.equal(takeAiPostDraft(app, 2), '');
});

test('new sessions send only explicit titles and reject titles beyond the shared limit', async () => {
  const titles = [];
  const state = Object.assign(initialWritingState(), {availability:'enabled', draft:'private source text'});
  const controller = createWritingController({
    async create(_signal,title) {titles.push(title);return {conversation_id:'new'}},
    async append() {},
    async generate() {},
    async messages() {return []},
  },state);
  state.titleDraft = '😀'.repeat(101);
  await controller.send();
  assert.equal(state.error,'title-too-long');
  assert.deepEqual(titles,[]);
  state.titleDraft = '  公告草稿  ';
  await controller.send();
  assert.deepEqual(titles,['公告草稿']);
  assert.equal(state.titleDraft,'');
  controller.reset();
  state.draft = 'second private draft';
  await controller.send();
  assert.deepEqual(titles,['公告草稿',undefined]);
});

test('writing byte budget includes the mode instruction and prevents an overlong conversation write', async () => {
  const state = Object.assign(initialWritingState(), {availability:'enabled', draft:'界'.repeat(21844)});
  const instruction = '改';
  let created = 0;
  const stored = [];
  const controller = createWritingController({
    async create() {created++; return {conversation_id:'new'};},
    async append(_id, content) {stored.push({message_id:'u', sequence_no:1, role:'user', content}); return 1;},
    async messages() {return stored;},
    async generate() {},
  }, state);
  assert.equal(aiMessageBytes(aiMessageContent(state.draft, instruction)), aiMessageMaxBytes + 1);
  await controller.send(instruction);
  assert.equal(state.error, 'too-long');
  assert.equal(created, 0);
  assert.equal(state.draft.length, 21844);

  state.draft = '界'.repeat(21843) + 'ab';
  await controller.send(instruction);
  assert.equal(created, 1);
  assert.equal(aiMessageBytes(stored[0].content), aiMessageMaxBytes);
});

test('stopping generation preserves the submitted message and reconciles a late commit', async () => {
  const started = Promise.withResolvers();
  const receipt = Promise.withResolvers();
  const state = Object.assign(initialWritingState(),{availability:'enabled',id:'id',draft:'keep this question'});
  const stored = [];
  let calls = 0;
  const controller = createWritingController({
    async append(id,content) {stored.push({message_id:'u',sequence_no:1,role:'user',content});return 1;},
    async generate(id,phrase,signal) {calls++; started.resolve(signal); return receipt.promise;},
    async messages() {return [...stored];},
  },state);
  const sending = controller.send('Polish the following text.');
  const signal = await started.promise;
  assert.equal(state.generating,true);
  controller.stopGeneration();
  assert.equal(signal.aborted,true);
  stored.push({message_id:'a',sequence_no:2,role:'assistant',content:'committed reply'});
  receipt.resolve({});
  await sending;
  assert.equal(state.error,'generation-stopped');
  assert.equal(state.refreshRequired,true);
  assert.equal(state.generating,false);
  assert.deepEqual(state.messages.map(message=>message.role),['user']);
  assert.equal(state.messages[0].content,'Polish the following text.\n\nkeep this question');
  await controller.retry();
  assert.equal(calls,1);
  assert.deepEqual(state.messages.map(message=>message.role),['user','assistant']);
  assert.equal(state.refreshRequired,false);
});

test('a disappeared conversation restores the submitted draft and ignores stale history', async () => {
  const stale = Promise.withResolvers();
  const state = Object.assign(initialWritingState(),{id:'gone',draft:'keep my draft',availability:'enabled'});
  const appends = [];
  const unavailable = Object.assign(new Error('Not found'),{statusCode:404});
  const controller = createWritingController({
    async create() {return {conversation_id:'new'}},
    async append(id,content) {appends.push({id,content});return 1;},
    async generate(id) {if (id === 'gone') throw unavailable},
    async messages() {return [{message_id:'u',sequence_no:1,role:'user',content:'keep my draft'}]},
    list() {return stale.promise},
  },state);
  const listing = controller.loadHistory();
  await controller.send();
  stale.resolve({items:[{conversation_id:'gone',purpose:'writing'}],next_cursor:null});
  await listing;
  assert.equal(state.id,null);
  assert.equal(state.draft,'keep my draft');
  assert.equal(state.refreshRequired,false);
  assert.deepEqual(state.messages,[]);
  assert.deepEqual(state.history,[]);
  assert.equal(state.error,'conversation-missing');
  assert.equal(appends.length,1);
  await controller.send();
  assert.deepEqual(appends.map(entry=>entry.id),['gone','new']);
});

test('closing the session aborts a pending append and ignores the late receipt',async()=>{
  const begun = Promise.withResolvers();
  const receipt = Promise.withResolvers();
  const state = Object.assign(initialWritingState(),{availability:'enabled',id:'id',draft:'private draft'});
  const controller = createWritingController({
    append(id,content,signal){begun.resolve(signal);return receipt.promise},
    messages(){assert.fail('expired session must not load messages')},
    generate(){assert.fail('expired session must not generate')},
  },state);
  const pending = controller.send();
  const signal = await begun.promise;
  controller.close();
  assert.equal(signal.aborted,true);
  receipt.resolve({});
  await pending;
  assert.deepEqual(state,initialWritingState());
});

function fixture() {
  const state=Object.assign(initialWritingState(), {availability:'enabled'}), messages=[];
  let appends=0,generations=0,failGeneration=true;
  const api={
    async create(){return {conversation_id:'id'}},
    async append(id,content){appends++;messages.push({message_id:'u',sequence_no:1,role:'user',content});return 1;},
    async read(id){return {conversation_id:id,purpose:'writing'}},
    async generate(){generations++;if(failGeneration){failGeneration=false;throw Error('timeout')}messages.push({message_id:'a',sequence_no:2,role:'assistant',content:'draft'})},
    async messages(id,after){return messages.filter(m=>m.sequence_no>after)},
    async list(){return {items:[{conversation_id:'id',purpose:'writing',title:'draft',updated_at:'today'}],next_cursor:null}},
    async remove(){messages.length=0}
  };
  return {state,controller:createWritingController(api,state),stats:()=>({appends,generations})};
}
test('publishes a confirmed conversation before append or inference finishes', async () => {
  const id = 'f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb';
  const state = initialWritingState();
  state.availability = 'enabled';
  state.draft = 'unfinished';
  const events = [];
  let finishAppend;
  const pending = new Promise(resolve => { finishAppend = resolve; });
  const controller = createWritingController({
    async create() {events.push('create'); return {conversation_id:id}},
    async append() {events.push('append'); await pending; throw Error('offline')},
    async generate() {assert.fail('must await a confirmed append')}
  }, state);
  const send = controller.send(undefined, created => {
    assert.equal(created,id);
    assert.equal(state.id,id);
    events.push('link');
  });
  try {
    for (let attempt=0; attempt<10 && events.length<3; attempt++) await Promise.resolve();
    assert.deepEqual(events,['create','link','append']);
  } finally {
    finishAppend();
    await send;
  }
  assert.equal(state.id,id);
  assert.equal(state.draft,'unfinished');
  assert.equal(state.error,'append-unknown');
});

test('failed generation can be retried without appending user message again',async()=>{
  const f=fixture();f.state.draft='request';await f.controller.send();
  assert.equal(f.state.error,'generation');assert.equal(f.state.refreshRequired,true);
  await f.controller.retry();
  assert.deepEqual(f.stats(),{appends:1,generations:2});assert.equal(f.state.messages.at(-1).content,'draft');
});
test('send and retry never switch to a different user message in a concurrent session', async()=>{
  const state=Object.assign(initialWritingState(), {availability:'enabled',id:'id',draft:'my request'});
  const rows=[], sequences=[];
  const controller=createWritingController({
    async append(id,content){rows.push({message_id:'u1',sequence_no:1,role:'user',content});return 1;},
    async messages(){return [...rows];},
    async generate(_id,_phrase,_signal,_skill,sequence){
      sequences.push(sequence);
      rows.push({message_id:'u2',sequence_no:2,role:'user',content:'request from another device'});
      throw Object.assign(Error('conflict'),{statusCode:409});
    },
  },state);
  await controller.send();
  assert.deepEqual(sequences,[1]);
  assert.equal(state.error,'sequence-conflict');
  assert.equal(state.refreshRequired,true);
  await controller.retry();
  assert.deepEqual(sequences,[1]);
  assert.equal(state.messages.at(-1).sequence_no,2);
  assert.equal(state.error,'sequence-conflict');
});
test('existing conversation can be selected and deleted',async()=>{
  const f=fixture();await f.controller.loadHistory();assert.equal(f.state.history[0].title,'draft');
  await f.controller.select('id');assert.equal(f.state.id,'id');
  await f.controller.remove();assert.equal(f.state.id,null);assert.deepEqual(f.state.messages,[]);
});
test('invalid history page keeps the list and retries from the same cursor', async () => {
  const state = initialWritingState();
  const row = conversation_id => ({conversation_id, purpose:'writing'});
  const pages = [
    {items:[row('a')], next_cursor:'a'},
    {items:[row('b'), row('b')], next_cursor:null},
    {items:[row('b')], next_cursor:'c'},
    {items:[row('b')], next_cursor:null},
  ];
  const cursors = [];
  const controller = createWritingController({async list(cursor) {
    cursors.push(cursor);
    return pages.shift();
  }}, state);
  await controller.loadHistory();
  for (let retry = 0; retry < 2; retry++) {
    await controller.loadHistory(false);
    assert.equal(state.error, 'history');
    assert.deepEqual(state.history.map(x => x.conversation_id), ['a']);
    assert.equal(state.historyCursor, 'a');
  }
  await controller.loadHistory(false);
  assert.deepEqual(state.history.map(x => x.conversation_id), ['a', 'b']);
  assert.deepEqual(cursors, [null, 'a', 'a', 'a']);
  assert.equal(state.historyCursor, null);
});
test('a saved reply with unavailable history can be recovered without regenerating', async () => {
  const state = Object.assign(initialWritingState(), {availability:'enabled', draft:'question'});
  const messages = [{message_id:'user', sequence_no:1, role:'user', content:'question'}];
  let calls = 0;
  let offline = false;
  const controller = createWritingController({
    async create() { return {conversation_id:'id'}; }, async append() {return 1;},
    async generate() {
      calls++;
      messages.push({message_id:'reply', sequence_no:2, role:'assistant', content:'draft'});
      offline = true;
    },
    async messages() { if (offline) throw Error('offline'); return [...messages]; },
  }, state);
  await controller.send();
  assert.equal(state.error, 'reply-saved');
  assert.equal(state.refreshRequired, true);
  await controller.retry();
  assert.equal(calls, 1);
  offline = false;
  await controller.retry(false);
  assert.equal(calls, 1);
  assert.equal(state.savedReplyPending, false);
  assert.equal(state.messages.at(-1).content, 'draft');
});
test('restores the recent window and prepends earlier messages on demand', async () => {
  const messages = Array.from({length: 55}, (_, index) => ({
    message_id: String(index + 1), sequence_no: index + 1, role: 'user', content: 'message',
  }));
  for (const legacy of [false, true]) {
    const state = initialWritingState();
    const calls = [];
    const controller = createWritingController({
      async read(id) { return {conversation_id:id,purpose:'writing'}; },
      async messages(id, after, signal, before) {
        calls.push([after, before]);
        if (before !== undefined && !legacy) return messages.filter(m => m.sequence_no < before).slice(-50);
        return messages.filter(m => m.sequence_no > after).slice(0, 50);
      },
    }, state);
    await controller.select('conversation');
    assert.deepEqual(state.messages.map(m=>m.sequence_no), messages.slice(5).map(m=>m.sequence_no));
    assert.deepEqual(calls, legacy ? [[0, 10000000000], [50, undefined]] : [[0, 10000000000]]);
    assert.equal(state.hasOlderMessages, true);
    await controller.loadOlderMessages();
    assert.deepEqual(state.messages.map(m=>m.sequence_no), messages.map(m=>m.sequence_no));
    assert.equal(state.hasOlderMessages, false);
  }
});
test('an empty older history page ends pagination without clearing current messages', async () => {
  const messages = Array.from({length:50}, (_, index) => ({
    message_id:String(index + 4), sequence_no:index + 4, role:'user', content:'message',
  }));
  const state = initialWritingState();
  const calls = [];
  const controller = createWritingController({
    async read(id) { return {conversation_id:id,purpose:'writing'}; },
    async messages(_id, _after, _signal, before) {
      calls.push(before);
      return messages.filter(message => message.sequence_no < before);
    },
  }, state);
  await controller.select('conversation');
  assert.equal(state.hasOlderMessages, true);
  await controller.loadOlderMessages();
  assert.equal(state.error, null);
  assert.equal(state.hasOlderMessages, false);
  assert.deepEqual(state.messages.map(message => message.sequence_no), messages.map(message => message.sequence_no));
  await controller.loadOlderMessages();
  assert.deepEqual(calls, [10000000000, 4]);
});
test('restoration reads messages only after matching conversation identity and purpose', async () => {
  const state = initialWritingState();
  let record = { conversation_id: 'id', purpose: 'knowledge' };
  let messageReads = 0;
  const controller = createWritingController({
    async read() { return record; },
    async messages() { messageReads++; return []; },
  }, state);

  await controller.select('id');
  assert.equal(state.error, 'conversation-missing');
  record = { conversation_id: 'other', purpose: 'writing' };
  await controller.select('id');
  assert.equal(state.error, 'conversation-missing');
  assert.equal(state.id, null);
  assert.equal(messageReads, 0);

  record = { conversation_id: 'id', purpose: 'writing' };
  await controller.select('id', () => false);
  assert.equal(messageReads, 0);
  await controller.select('id');
  assert.equal(state.id, 'id');
  assert.equal(messageReads, 1);
});

test('forward-only history finds earlier messages across sequence gaps', async () => {
  const sequences = [1, 4, ...Array.from({length:50}, (_, index) => 200 + index)];
  const messages = sequences.map(sequence => ({
    message_id:String(sequence), sequence_no:sequence, role:'user', content:'message',
  }));
  const state = initialWritingState();
  const controller = createWritingController({
    async read(id) { return {conversation_id:id,purpose:'knowledge'}; },
    async messages(_id, after) { return messages.filter(message => message.sequence_no > after).slice(0,50); },
  }, state, 'knowledge');
  await controller.select('conversation');
  assert.deepEqual(state.messages.map(message => message.sequence_no),sequences.slice(-50));
  await controller.loadOlderMessages();
  assert.deepEqual(state.messages.map(message => message.sequence_no),sequences);
  assert.equal(state.hasOlderMessages,false);
});
test('unknown append is never automatically repeated and requires refresh',async()=>{
  const state=Object.assign(initialWritingState(), {availability:'enabled'});let appends=0;
  const api={async create(){return {conversation_id:'id'}},async append(){appends++;throw Error('timeout')},async generate(){throw Error('unexpected')},async messages(){return []},async list(){return {items:[],next_cursor:null}},async remove(){}};
  const controller=createWritingController(api,state);state.draft='request';await controller.send();await controller.send();
  assert.equal(appends,1);assert.equal(state.refreshRequired,true);assert.equal(state.error,'append-unknown');
  await controller.retry(false);assert.equal(state.refreshRequired,false);assert.equal(state.draft,'request');
});
test('reopening current knowledge history preserves local input and never resends', async () => {
  const state = Object.assign(initialWritingState(), {id:'id', availability:'enabled', refreshRequired:true});
  const saved = {message_id:'saved', sequence_no:1, role:'user', content:'previous question'};
  const controller = createWritingController({
    async read(id) { return {conversation_id:id, purpose:'knowledge'}; },
    async messages(_id, after) { return after < 1 ? [saved] : []; },
    async append() { assert.fail('history refresh appended a message'); },
    async generate() { assert.fail('history refresh started inference'); },
  }, state, 'knowledge');

  state.draft = 'next question';
  state.searchPhrase = 'search phrase';
  await controller.select('id');

  assert.equal(state.error, null);
  assert.equal(state.refreshRequired, false);
  assert.equal(state.draft, 'next question');
  assert.equal(state.searchPhrase, 'search phrase');
  assert.deepEqual(state.messages.map(message => message.message_id), ['saved']);
});
test('failed delete preserves current conversation and reports uncertainty',async()=>{
  const state=Object.assign(initialWritingState(), {availability:'enabled'});state.id='id';state.messages=[{message_id:'a',sequence_no:1,role:'assistant',content:'draft'}];
  const api={async create(){return {conversation_id:'id'}},async append(){},async generate(){},async messages(){return []},async list(){return {items:[],next_cursor:null}},async remove(){throw Error('timeout')}};
  await createWritingController(api,state).remove();assert.equal(state.id,'id');assert.equal(state.messages[0].content,'draft');assert.equal(state.error,'delete-unknown');
});
