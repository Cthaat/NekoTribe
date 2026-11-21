import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { compileScript, parse } from '@vue/compiler-sfc';
import { build } from 'esbuild';
import * as vue from 'vue';

const root = fileURLToPath(new URL('../', import.meta.url));
const file = 'app/components/ModerationAdvicePanel.vue';
const { descriptor } = parse(readFileSync(root + file, 'utf8'), { filename:file });
const component = compileScript(descriptor, { id:'moderation-advice-panel', inlineTemplate:true });
globalThis.__moderationAdviceVue = vue;
const stubs = {
  vue:Object.keys(vue).filter(key => /^[a-zA-Z_$][\w$]*$/.test(key))
    .map(key => `export const ${key}=globalThis.__moderationAdviceVue.${key};`).join('\n'),
  './client':'export const v2RequestData=(path,options)=>globalThis.__moderationAdviceClient.request(path,options);',
  '@/components/ui/button':`export const Button={inheritAttrs:false,setup(p,{attrs,slots}){
    return ()=>globalThis.__moderationAdviceVue.h('button',attrs,slots.default?.());
  }};`,

};
const bundle = await build({
  stdin:{contents:component.content+'\nexport {authQueueFor} from "./app/services/auth-request-queue";',loader:'ts',resolveDir:root},
  bundle:true,write:false,platform:'node',format:'esm',alias:{'@':root+'app'},
  banner:{js:`
    const useAppLocale=()=>({t:(key,params)=>key==='aiReplyConfigRevision'?key+':'+params.revision:key,locale:{value:"en"}});
    const useLocalePath=()=>value=>value;
    const useNuxtApp=()=>globalThis.__moderationAdviceClient.app;
  `},
  plugins:[{name:'client-boundaries',setup(builder){
    builder.onResolve({filter:/^@\/components\/AiSkillStatus\.vue$/},({path})=>({path,namespace:'skill-status'}));
    builder.onLoad({filter:/.*/,namespace:'skill-status'},()=>{
      const filename='app/components/AiSkillStatus.vue';
      const {descriptor}=parse(readFileSync(root+filename,'utf8'),{filename});
      return {contents:compileScript(descriptor,{id:'ai-skill-status',inlineTemplate:true}).content,loader:'ts',resolveDir:root};
    });
    builder.onResolve({filter:/.*/},({path})=>Object.hasOwn(stubs,path)?{path,namespace:'stub'}:undefined);
    builder.onLoad({filter:/.*/,namespace:'stub'},({path})=>({contents:stubs[path],loader:'js'}));
  }}],
});
const { default:Panel, authQueueFor }=await import(`data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].text).toString('base64')}`);
const detach = node => {
  const parent = node.parent;
  if (!parent) return;
  const index = parent.children.indexOf(node);
  if (index >= 0) parent.children.splice(index, 1);
  node.parent = null;
};
const renderer = vue.createRenderer({
  createElement:type=>({type,children:[],props:{},options:[],addEventListener(){},removeEventListener(){}}),
  createText:text=>({text}), createComment:text=>({comment:text}),
  setText:(node,text)=>{node.text=text;},
  setElementText:(node,text)=>{node.text=text;node.children=[];},
  patchProp:(node,key,old,value)=>{node.props[key]=value;},
  parentNode:node=>node.parent,
  nextSibling:node=>node.parent?.children[node.parent.children.indexOf(node)+1],
  insert(node,parent,anchor){
    detach(node);node.parent=parent;
    const index=anchor?parent.children.indexOf(anchor):-1;
    if(index<0)parent.children.push(node);else parent.children.splice(index,0,node);
  },
  remove:detach,
});

const id = 'f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb';
const unrelatedId = 'e7dd4d7f-8462-45b6-9bf4-a630d0ba7478';
const secondaryId = 'f9d50a00-e8bd-46bd-acb3-83d9a901fc6a';
const messageId = sequence => `2625acec-6d03-42ee-92f5-${String(sequence).padStart(12, '0')}`;
const base = '/api/v2/ai/conversations';
const generate = `${base}/${id}/moderation-generate`;
const feedbackPath = (conversation, message) => `${base}/${conversation}/messages/${message}/moderation-feedback`;
const flush = async () => { await new Promise(resolve => setImmediate(resolve)); await vue.nextTick(); };
const descendants = node => [node, ...(node.children ?? []).flatMap(descendants)];
const nodeText = node => [node.text ?? '', ...(node.children ?? []).map(nodeText)].join('').trim();

async function fixture(t, kind = 'group_comment') {
  const host = {children:[]};
  const owner = {runWithContext:action => action()};
  const requests = [];
  const conversation = (conversation_id, title) => ({conversation_id, purpose:'moderation', group_id:null, title});
  function historyRow(conversation, sequence) {
    const messageIdValue = messageId(sequence);
    return {
      message_id:messageIdValue, conversation_id:conversation, sequence_no:sequence, role:'assistant',
      created_at:`2026-11-17T12:00:${String(sequence).padStart(2,'0')}Z`,
      content:'Never show raw fallback',
      model_version:'review-build-3',
      config_revision:3,
      moderation_feedback:state.ratings.get(messageIdValue),
      moderation_advice:state.invalidated ? null : {
        risk:'spam',reason:'Possible repeated solicitation',recommendation:'human_review',rule_ids:[7,6],
        target:{kind:state.mismatch?'post':'group_post_comment',id:17,post_id:27,group_id:state.groupId},
        rules:[{kind:'terms',id:6,version:'a'.repeat(64)},{kind:'terms',id:7,version:'b'.repeat(64)}],
      },
    };
  }
  const state = {
    app:owner, created:true, sequence:1, invalidated:false, mismatch:false, groupId:7, pending:null, conflict:false,
    secondary:false, ratings:new Map(), feedbackError:null, wrongReceipt:false, pendingFeedback:null, deleteError:false, historyUnavailable:false,
    async request(path, options) {
      if (path === '/api/v2/ai/availability') return {knowledge:true, writing:true, moderation:true};
      requests.push({path, options});
      const title = 'moderation:group_post_comment:17';
      if (path === base && options.method === 'POST') {
        assert.deepEqual(options.body, {purpose:'moderation',title});
        state.created = true;
        return conversation(id, title);
      }
      if (path === base) {
        assert.equal(options.query.purpose,'moderation');
        assert.equal(options.query.target_type,'group_post_comment');
        assert.equal(options.query.target_id,17);
      }
      if (path === base) return {
        items:[
          conversation(unrelatedId,'moderation:post:17'),
          ...(state.created ? [conversation(id,title)] : []),
          ...(state.secondary ? [conversation(secondaryId,title)] : []),
        ],
        next_cursor:state.invalidHistoryCursor ? unrelatedId : null,
      };
      if (path === `${base}/${id}` && options.method === 'DELETE') {
        if (state.deleteError) throw new Error('Connection lost');
        state.created = false;
        return null;
      }
      if (path === `${base}/${secondaryId}` && options.method === 'DELETE') {
        state.secondary = false;
        return null;
      }
      if (path === generate) {
        if (state.pending) await state.pending;
        if (state.conflict) throw Object.assign(new Error('Conflict'), {statusCode:409});
        const sequence_no = ++state.sequence;
        return {status:'generated', message:{conversation_id:id, message_id:messageId(sequence_no),sequence_no,role:'assistant'}};
      }
      if (path === `${base}/${id}/messages` && !state.created) {
        throw Object.assign(Error('Conversation missing'), {statusCode:404});
      }
      if (path === `${base}/${id}/messages` && state.historyUnavailable) throw Error('History offline');
      if (path === `${base}/${id}/messages`) {
        const {before_sequence:before,after_sequence:after,limit}=options.query;
        const rows=Array.from({length:state.sequence},(_,offset)=>historyRow(id,offset+1));
        return before===undefined || state.legacyCursor
          ? rows.filter(row=>row.sequence_no>(after??0)).slice(0,limit)
          : rows.filter(row=>row.sequence_no<before).slice(-limit);
      }
      if (path === `${base}/${secondaryId}/messages`) {
        const {before_sequence: before, after_sequence: after} = options.query;
        return (before === undefined || before > 9) && (after === undefined || after < 9)
          ? [historyRow(secondaryId, 9)] : [];
      }
      if (options.method === 'PUT' && path.endsWith('/moderation-feedback')) {
        if (state.pendingFeedback) await state.pendingFeedback;
        if (state.feedbackError) throw Object.assign(new Error('Rating failed'), {statusCode:state.feedbackError});
        const message = path.split('/').at(-2);
        if (!state.unconfirmedRating) state.ratings.set(message,options.body.rating);
        return {message_id:state.wrongReceipt ? messageId(42) : message,rating:options.body.rating};
      }
      throw Error(`Unexpected client request: ${path}`);
    },
  };
  globalThis.__moderationAdviceClient = state;
  const app = renderer.createApp(Panel, {kind,targetId:17});
  app.mount(host);
  t.after(() => { app.unmount(); delete globalThis.__moderationAdviceClient; });
  await flush();
  return {
    state, requests, owner, text:() => nodeText(host), all:() => descendants(host),
    button(key) { return descendants(host).find(node => node.type === 'button' && nodeText(node) === `moderationAdvice.${key}`); },
    async click(key) {
      const button = this.button(key);
      assert(button && !button.props.disabled, key);
      button.props.onClick();
      await flush();
    },
  };
}

test('invalid moderation history cursor is rejected before reading advice', async t => {
  const f = await fixture(t);
  f.state.invalidHistoryCursor = true;
  await f.click('title');
  assert.equal(f.requests.some(request => request.path.endsWith('/messages')), false);
  f.state.invalidHistoryCursor = false;
  await f.click('refresh');
  assert.match(f.text(), /Possible repeated solicitation/);
});

test('saved moderation advice is recovered without a second generation', async t => {
  const f = await fixture(t);
  await f.click('title');
  f.state.historyUnavailable = true;
  await f.click('generate');
  assert.match(f.text(), /moderationAdvice\.generationSaved/);
  assert.equal(f.button('generate').props.disabled, true);
  f.state.historyUnavailable = false;
  await f.click('refresh');
  assert.match(f.text(), /Possible repeated solicitation/);
  assert.equal(f.requests.filter(request=>request.path===generate).length,1);
});

test('only a valid reviewed group comment gets its exact source link', async t => {
  const f = await fixture(t);
  await f.click('title');
  const source = () => f.all().find(node => node.type === 'a' && nodeText(node) === 'moderationAdvice.openSource');
  assert.deepEqual(source()?.props.href, {
    path:'/groups/posts', query:{group:7,post:27,comment:17}
  });
  assert.equal(source()?.props.target, '_blank');
  f.state.groupId = null;
  await f.click('refresh');
  assert.equal(source(), undefined);
  assert.match(f.text(), /Possible repeated solicitation/);
});

test('Web loads older moderation suggestions on demand without changing the generation sequence', async t => {
  const f = await fixture(t);
  f.state.sequence = 53;
  f.state.invalidated = true;
  const queries = () => f.requests.filter(r=>r.path===`${base}/${id}/messages`).map(r=>r.options.query);
  const times = () => f.all().filter(node=>node.type==='time').map(node=>node.props.datetime);
  await f.click('title');
  assert.deepEqual(queries(), [{before_sequence:10000000000,limit:50}]);
  assert.equal(times().length, 50);
  assert.match(times()[0], /:53Z$/);
  const older = f.all().find(node=>node.type==='button' && nodeText(node)==='chat.directMessage.loadOlder');
  assert(older);
  older.props.onClick();
  await flush();
  assert.deepEqual(queries().at(-1), {before_sequence:4,limit:50});
  assert.equal(times().length, 53);
  await f.click('generate');
  assert.equal(f.requests.find(r=>r.path===generate).options.body.expected_sequence, 53);
});

test('Web bounds the moderation history on older forward-only backends', async t => {
  const f = await fixture(t);
  f.state.sequence = 53;
  f.state.legacyCursor = true;
  const queries = () => f.requests.filter(r=>r.path===`${base}/${id}/messages`).map(r=>r.options.query);
  const times = () => f.all().filter(node=>node.type==='time').map(node=>node.props.datetime);
  await f.click('title');
  assert.deepEqual(queries(), [{before_sequence:10000000000,limit:50},{after_sequence:50,limit:50}]);
  assert.equal(times().length, 50);
  const older = f.all().find(node=>node.type==='button' && nodeText(node)==='chat.directMessage.loadOlder');
  assert(older);
  older.props.onClick();
  await flush();
  assert.deepEqual(queries().at(-1), {after_sequence:0,limit:50});
  assert.equal(times().length, 53);
  await f.click('generate');
  assert.equal(f.requests.find(r=>r.path===generate).options.body.expected_sequence, 53);
});

test('Web older history drops a deleted conversation and keeps other suggestions', async t => {
  const f = await fixture(t);
  f.state.sequence = 53;
  f.state.secondary = true;
  await f.click('title');
  const times = () => f.all().filter(node => node.type === 'time').map(node => node.props.datetime);
  assert.equal(times().length, 51);
  const readsOfShortConversation = () => f.requests.filter(request => request.path === `${base}/${secondaryId}/messages`).length;
  const shortReads = readsOfShortConversation();
  f.state.created = false;
  const older = f.all().find(node => node.type === 'button' && nodeText(node) === 'chat.directMessage.loadOlder');
  assert(older);
  older.props.onClick();
  await flush();
  assert.deepEqual(times(), ['2026-11-17T12:00:09Z']);
  assert.equal(readsOfShortConversation(), shortReads);
  assert(!f.button('generate').props.disabled);
  assert(!f.requests.some(request => ['POST', 'DELETE', 'PUT'].includes(request.options.method)));
});

test('Web confirms a rating on an older suggestion without resetting the visible pages', async t => {
  const f = await fixture(t);
  f.state.sequence = 53;
  await f.click('title');
  f.all().find(node => node.type === 'button' && nodeText(node) === 'chat.directMessage.loadOlder').props.onClick();
  await flush();
  const articles = () => f.all().filter(node => node.type === 'article');
  const rating = key => descendants(articles().at(-1)).find(node => node.type === 'button' && nodeText(node) === `moderationAdvice.feedback.${key}`);
  assert.equal(articles().length, 53);
  rating('helpful').props.onClick();
  await flush();
  assert.equal(f.requests.at(-2).path, feedbackPath(id, messageId(1)));
  assert.deepEqual(f.requests.at(-1).options.query, {after_sequence:0, limit:1});
  assert.equal(articles().length, 53);
  assert.equal(rating('helpful').props['aria-pressed'], true);

  f.state.unconfirmedRating = true;
  rating('incorrect').props.onClick();
  await flush();
  assert.equal(articles().length, 0);
  assert.match(f.text(), /moderationAdvice\.conflict/);
  assert.doesNotMatch(f.text(), /moderationAdvice\.feedbackSaved/);
});

test('Web confirms removal of only the current conversation and refreshes the remaining history', async t => {
  const f = await fixture(t);
  f.state.secondary = true;
  await f.click('title');
  await f.click('deleteConversation');
  assert.equal(f.requests.filter(request => request.options.method === 'DELETE').length, 0);
  await f.click('confirmDelete');
  assert.deepEqual(f.requests.filter(request => request.options.method === 'DELETE').map(request => request.path), [`${base}/${id}`]);
  assert.match(f.text(), /moderationAdvice\.deleted/);
  assert(f.requests.some(request => request.path === `${base}/${secondaryId}/messages`));
  assert.match(f.text(), /Possible repeated solicitation/);
});

test('Web ignores a confirmation captured under the previous identity', async t => {
  const f = await fixture(t);
  await f.click('title');
  await f.click('deleteConversation');
  const confirm = f.button('confirmDelete').props.onClick;
  authQueueFor(f.owner).beginIdentityChange();
  confirm();
  await flush();
  assert.equal(f.requests.filter(request => request.options.method === 'DELETE').length, 0);
  assert.doesNotMatch(f.text(), /Possible repeated solicitation/);
});

test('Web can remove a historical conversation without removing the active one', async t => {
  const f = await fixture(t);
  f.state.secondary = true;
  await f.click('title');
  await f.click('deleteHistoricalConversation');
  assert.match(f.text(), /moderationAdvice\.deleteHistoricalPrompt/);
  assert.equal(f.requests.filter(request => request.options.method === 'DELETE').length, 0);
  await f.click('confirmDelete');
  assert.deepEqual(f.requests.filter(request => request.options.method === 'DELETE').map(request => request.path), [`${base}/${secondaryId}`]);
  assert(f.button('deleteConversation'));
  assert.equal(f.button('deleteHistoricalConversation'), undefined);
  assert.match(f.text(), /Possible repeated solicitation/);
});

test('Web requires refresh after an uncertain deletion without retrying it', async t => {
  const f = await fixture(t);
  f.state.deleteError = true;
  await f.click('title');
  await f.click('deleteConversation');
  await f.click('confirmDelete');
  assert.match(f.text(), /moderationAdvice\.deleteUnknown/);
  assert.doesNotMatch(f.text(), /Possible repeated solicitation/);
  await f.click('refresh');
  assert.match(f.text(), /Possible repeated solicitation/);
  assert.equal(f.requests.filter(request => request.options.method === 'DELETE').length, 1);
});

test('Web restores only the selected target and uses its sequence without submitting a case decision', async t => {
  const f = await fixture(t);
  assert.equal(f.requests.length, 0);
  await f.click('title');
  assert.match(f.text(), /Possible repeated solicitation/);
  assert.match(f.text(), /aiModelVersion · review-build-3/);
  assert.match(f.text(), /aiReplyConfigRevision:3/);
  assert(f.all().some(node => node.type === 'a' && node.props.href === `/en/auth/terms?citation=7.${'b'.repeat(64)}#conduct`));
  assert(!f.requests.some(request => request.path.includes(unrelatedId)));
  await f.click('generate');
  assert.deepEqual(f.requests.filter(request => request.options.method === 'POST').map(({path,options}) => ({path,body:options.body})),
    [{path:generate,body:{target_type:'group_post_comment',target_id:17,locale:'en',expected_sequence:1}}]);
  f.state.invalidated = true;
  await f.click('refresh');
  assert.match(f.text(), /moderationAdvice\.expired/);
  assert.doesNotMatch(f.text(), /Possible repeated solicitation|Never show raw fallback|review-build-3|aiReplyConfigRevision/);
  assert(!f.all().some(node => node.type === 'a'));
});

test('Web creates the target conversation only on explicit request and requires refresh after a conflict', async t => {
  const f = await fixture(t);
  f.state.created = false;
  f.state.sequence = 0;
  f.state.conflict = true;
  await f.click('title');
  assert.equal(f.requests.length, 1);
  await f.click('generate');
  assert.match(f.text(), /moderationAdvice\.conflict/);
  assert.equal(f.button('generate').props.disabled, true);
  assert.equal(f.requests.filter(request => request.path === generate).length, 1);
  await f.click('refresh');
  assert.equal(f.button('generate').props.disabled, false);
  assert.equal(f.requests.filter(request => request.path === generate).length, 1);
});

test('Web stops generation, ignores a late receipt, and requires refreshing the advice history', async t => {
  const f = await fixture(t);
  await f.click('title');
  let resolve;
  f.state.pending = new Promise(release => { resolve = release; });
  await f.click('generate');
  const request = f.requests.find(entry => entry.path === generate);
  await f.click('stopGeneration');
  assert(request.options.signal.aborted);
  assert.match(f.text(), /moderationAdvice\.generationStopped/);
  assert.equal(f.button('generate').props.disabled, true);
  resolve();
  await flush();
  assert.equal(f.requests.at(-1), request);
  await f.click('refresh');
  assert.match(f.text(), /Possible repeated solicitation/);
  assert.equal(f.button('generate').props.disabled, false);
  assert.equal(f.requests.filter(entry => entry.path === generate).length, 1);
});

test('Web clears and cancels the current request when the account changes', async t => {
  const f = await fixture(t);
  await f.click('title');
  let resolve;
  f.state.pending = new Promise(release => { resolve = release; });
  await f.click('generate');
  const request = f.requests.find(entry => entry.path === generate);
  authQueueFor(f.owner).beginIdentityChange();
  assert(request.options.signal.aborted);
  resolve();
  await flush();
  assert.match(f.text(), /moderationAdvice\.sessionChanged/);
  assert.doesNotMatch(f.text(), /Possible repeated solicitation/);
  assert.equal(f.requests.at(-1), request);
});

test('Web omits advice for unsupported targets and suppresses mismatched evidence', async t => {
  await t.test('unsupported user target', async subtest => {
    const f = await fixture(subtest, 'user');
    assert.equal(f.button('title'), undefined);
    assert.equal(f.requests.length, 0);
  });
  await t.test('mismatched evidence', async subtest => {
    const f = await fixture(subtest);
    f.state.mismatch = true;
    await f.click('title');
    assert.doesNotMatch(f.text(), /Possible repeated solicitation|Never show raw fallback/);
  });
});

test('Web rates a merged history entry through its own conversation and confirms from refreshed history', async t => {
  const f = await fixture(t);
  f.state.secondary = true;
  f.state.ratings.set(messageId(9),'helpful');
  await f.click('title');
  assert.equal(f.button('feedback.helpful').props['aria-pressed'],true);
  await f.click('feedback.helpful');
  assert(!f.requests.some(request=>request.options.method==='PUT'));
  await f.click('feedback.incorrect');
  const put = f.requests.find(request=>request.options.method==='PUT');
  assert.equal(put.path,feedbackPath(secondaryId,messageId(9)));
  assert.deepEqual(put.options.body,{rating:'incorrect'});
  assert.match(f.text(),/moderationAdvice\.feedbackSaved/);
  assert.equal(f.button('feedback.incorrect').props['aria-pressed'],true);
  f.state.invalidated = true;
  await f.click('refresh');
  assert.equal(f.button('feedback.incorrect'),undefined);
});

test('Web discards a stale rating and requires refresh after an invalid write receipt', async t => {
  const f = await fixture(t);
  await f.click('title');
  f.state.wrongReceipt = true;
  await f.click('feedback.helpful');
  assert.match(f.text(),/moderationAdvice\.feedbackFailed/);
  assert.equal(f.button('feedback.helpful'),undefined);
  assert.equal(f.requests.filter(request=>request.options.method==='PUT').length,1);
  await f.click('refresh');
  assert.equal(f.button('feedback.helpful').props['aria-pressed'],true);
  f.state.feedbackError = 409;
  f.state.invalidated = true;
  await f.click('feedback.insufficient');
  assert.match(f.text(),/moderationAdvice\.conflict/);
  await f.click('refresh');
  assert.match(f.text(),/moderationAdvice\.expired/);
  assert.equal(f.button('feedback.insufficient'),undefined);
});

test('Web cancels in-flight rating on an identity change and ignores the late receipt', async t => {
  const f = await fixture(t);
  await f.click('title');
  let resolve;
  f.state.pendingFeedback = new Promise(release=>{resolve=release;});
  await f.click('feedback.helpful');
  const request=f.requests.at(-1);
  assert.equal(request.options.method,'PUT');
  assert.equal(f.button('feedback.incorrect').props.disabled,true);
  authQueueFor(f.owner).beginIdentityChange();
  assert(request.options.signal.aborted);
  resolve();
  await flush();
  assert.equal(f.requests.at(-1),request);
  assert.match(f.text(),/moderationAdvice\.sessionChanged/);
  assert.equal(f.button('feedback.helpful'),undefined);
});
