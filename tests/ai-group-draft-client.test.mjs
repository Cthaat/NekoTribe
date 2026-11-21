import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { compileScript, parse } from '@vue/compiler-sfc';
import { build } from 'esbuild';
import * as vue from 'vue';

const root = fileURLToPath(new URL('../', import.meta.url));
const file = 'app/components/GroupDraftPanel.vue';
const { descriptor } = parse(readFileSync(root + file, 'utf8'), { filename:file });
const component = compileScript(descriptor, { id:'group-draft-panel', inlineTemplate:true });
globalThis.__groupDraftVue = vue;
const stubs = {
  vue:Object.keys(vue).filter(key => /^[a-zA-Z_$][\w$]*$/.test(key))
    .map(key => `export const ${key}=globalThis.__groupDraftVue.${key};`).join('\n'),
  './client':`export const v2RequestData=(path,options)=>globalThis.__groupDraftClient.request(path,options);
    export const v2Request=v2RequestData; export const toV2PagedResult=value=>value;`,
  '@/services/groups':`
    import {v2CreateGroupPost} from './app/api/v2/groups';
    export const getGroup=id=>globalThis.__groupDraftClient.group(id);
    export const createGroupPost=async(id,body,signal)=>({id:(await v2CreateGroupPost(id,body,signal)).post_id});
  `,
  '@/stores/user':'export const usePreferenceStore=()=>({isLoggedIn:true});',
  '@/components/ui/button':`export const Button={inheritAttrs:false,setup(p,{attrs,slots}){
    return ()=>globalThis.__groupDraftVue.h('button',attrs,slots.default?.());
  }};`,
  '@/components/ui/textarea':`export const Textarea={props:['modelValue'],emits:['update:modelValue'],
    setup(p,{attrs,emit}){return ()=>globalThis.__groupDraftVue.h('textarea',{
      ...attrs,value:p.modelValue,onInput:value=>emit('update:modelValue',value)
    });}
  };`,
};
const bundle = await build({
  stdin:{contents:component.content+'\nexport {authQueueFor} from "./app/services/auth-request-queue";',loader:'ts',resolveDir:root},
  bundle:true,write:false,platform:'node',format:'esm',alias:{'@':root+'app'},
  banner:{js:`
    const useAppLocale=()=>({t:(key,values)=>key==='aiGroupDraft.quotaRetry' ? key+':'+values.seconds : key==='aiReplyConfigRevision' ? key+':'+values.revision : key});
    const useLocalePath=()=>value=>value;
    const useNuxtApp=()=>globalThis.__groupDraftClient.app;
  `},
  plugins:[{name:'client-boundaries',setup(builder){
    builder.onResolve({filter:/^@\/components\/AiSkillStatus\.vue$/},({path})=>({path,namespace:'skill-status'}));
    builder.onLoad({filter:/.*/,namespace:'skill-status'},()=>{
      const filename='app/components/AiSkillStatus.vue';
      const {descriptor}=parse(readFileSync(root+filename,'utf8'),{filename});
      return {contents:compileScript(descriptor,{id:'ai-skill-status',inlineTemplate:true}).content,loader:'ts',resolveDir:root};
    });
    builder.onResolve({filter:/.*/},({path})=>Object.hasOwn(stubs,path)?{path,namespace:'stub'}:undefined);
    builder.onLoad({filter:/.*/,namespace:'stub'},({path})=>({contents:stubs[path],loader:'js',resolveDir:root}));
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
  createElement:type=>({type,children:[],props:{},options:[],listeners:{},
    addEventListener(name,listener){this.listeners[name]=listener;},removeEventListener(){}}),
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

const id='f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb', other='e7dd4d7f-8462-45b6-9bf4-a630d0ba7478';
const base='/api/v2/ai/conversations', generate=`${base}/${id}/group-generate`;
const flush=async()=>{await new Promise(resolve=>setImmediate(resolve));await vue.nextTick();};
const descendants=node=>[node,...(node.children??[]).flatMap(descendants)];
const nodeText=node=>[node.text??'',...(node.children??[]).map(nodeText)].join('').trim();
async function fixture(t, role='admin', groupState={isActive:true}) {
  const host={children:[]};
  const owner={runWithContext:action=>action()};
  const requests=[], publications=[];
  const conversation=(conversation_id,group_id,title)=>({conversation_id,purpose:'group',group_id,title,updated_at:'today'});
  const receipt={status:'generated',message:{conversation_id:id,message_id:'m',sequence_no:1,role:'assistant'}};
  const state={
    app:owner,generated:false,sourceHidden:false,pending:null,retryAfter:null,historyUnavailable:false,
    group:async groupId=>({id:groupId,name:'Target group',privacy:'public',membershipRole:role,membershipStatus:'active',...groupState}),
    publish:async(groupId,body)=>{publications.push({groupId,body});return {post_id:31,group_id:groupId,is_announcement:body.is_announcement};},
    async request(path,options) {
      if(path==='/api/v2/ai/availability') return {knowledge:true,writing:true,group:true};
      requests.push({path,options});
      if(path==='/api/v2/groups/7/posts' && options.method==='POST') return state.publish(7,options.body);
      if(path===base && options.method==='POST') return conversation(id,7,'Weekly');
      if(path===base) {
        assert.equal(options.query.purpose,'group');
        assert.equal(options.query.group_id,7);
        return {items:[conversation(other,8,'Hidden data'),conversation(id,7,'Weekly')],next_cursor:null};
      }
      if(path===`${base}/${id}` && options.method==='DELETE') return null;
      if(path===generate) {
        if(state.pending) await state.pending;
        if (state.retryAfter!==null) throw Object.assign(new Error('Rate limit'), {
          statusCode:429,response:{headers:new Headers({'Retry-After':String(state.retryAfter)})},
        });
        state.generated=true;
        return receipt;
      }
      if(path===`${base}/${id}/messages` && state.historyMissing) throw Object.assign(Error('Conversation gone'), {statusCode:404});
      if(path===`${base}/${id}/messages` && state.historyUnavailable) throw Error('History offline');
      if(path===`${base}/${id}/messages` && state.historySize) {
        const {before_sequence:before,after_sequence:after,limit}=options.query;
        const history=Array.from({length:state.historySize},(_,i)=>({
          conversation_id:state.wrongHistoryConversation ? other : id,
          message_id:`m${i+1}`,sequence_no:i+1,role:'assistant',content:`Draft sequence ${i+1}.`,
          group_sources:[{kind:'post',source_id:24,post_id:24}],
        }));
        return before !== undefined && !state.legacyCursor
          ? history.filter(row=>row.sequence_no<before).slice(-limit)
          : history.filter(row=>row.sequence_no>(after??0)).slice(0,limit);
      }
      if(path===`${base}/${id}/messages`) return state.generated?[{
        conversation_id:id,message_id:'m',sequence_no:1,role:'assistant',content:'Draft for review',
        model_version:'group-build-2',
        config_revision:2,
        group_sources:state.sourceHidden?[]:[
          {kind:'post',source_id:24,post_id:24},
          {kind:'comment',source_id:31,post_id:24},
        ],
      }]:[];
      throw Error('Unknown client request');
    }
  };
  globalThis.__groupDraftClient=state;
  const app=renderer.createApp(Panel,{groupId:7});
  app.component('NuxtLink',{setup(props,{attrs,slots}){return()=>vue.h('a',attrs,slots.default?.());}});
  app.mount(host);
  t.after(()=>{app.unmount();delete globalThis.__groupDraftClient;});
  await flush();
  return {
    state,requests,publications,owner,all:()=>descendants(host),text:()=>nodeText(host),
    button(label){return descendants(host).find(node=>node.type==='button'&&nodeText(node)===label);},
    async click(label){const node=this.button(label);assert(node,label);assert(!node.props.disabled,label);node.props.onClick();await flush();},
  };
}

test('Web panel checks current role and scopes history to the selected group',async t=>{
  const f=await fixture(t,'moderator');
  assert.match(f.text(),/aiGroupDraft\.forbidden/);
  assert.equal(f.requests.length,0);
});

for (const [label, group] of [['inactive', {isActive:false}], ['unverified', {}]]) {
  test(`Web panel does not request AI history for an ${label} group`, async t => {
    const f = await fixture(t, 'admin', group);
    assert.match(f.text(), /aiGroupDraft\.forbidden/);
    assert.equal(f.requests.length, 0);
    assert.equal(f.button('aiGroupDraft.generate'), undefined);
  });
}

test('Web rejects group draft history returned for a different conversation', async t => {
  const f = await fixture(t);
  f.state.historySize = 2;
  f.state.wrongHistoryConversation = true;
  await f.click('Weeklytoday');
  assert.doesNotMatch(f.text(), /Draft sequence/);
  assert.equal(f.button('aiGroupDraft.review'), undefined);
  f.state.wrongHistoryConversation = false;
  await f.click('common.refresh');
  assert.match(f.text(), /Draft sequence 2\./);
  assert.equal(f.requests.filter(request => request.options.method === 'POST').length, 0);
});

test('Web opens the newest drafts first and refreshes an older active edit by sequence',async t=>{
  const f=await fixture(t);
  f.state.historySize=53;
  const historyQueries=()=>f.requests.filter(r=>r.path===`${base}/${id}/messages`).map(r=>r.options.query);
  await f.click('Weeklytoday');
  assert.deepEqual(historyQueries(),[{before_sequence:10000000000,limit:50}]);
  assert.match(f.text(),/Draft sequence 53\./);
  assert.doesNotMatch(f.text(),/Draft sequence 1\./);
  f.state.historyUnavailable = true;
  await f.click('chat.directMessage.loadOlder');
  assert.match(f.text(), /Draft sequence 53\./);
  assert.doesNotMatch(f.text(), /Draft sequence 1\./);
  assert.deepEqual(historyQueries().at(-1), {before_sequence:4, limit:50});
  f.state.historyUnavailable = false;
  await f.click('chat.directMessage.loadOlder');
  assert.deepEqual(historyQueries().at(-1),{before_sequence:4,limit:50});
  assert.match(f.text(),/Draft sequence 1\./);
  assert(!f.button('chat.directMessage.loadOlder'));
  const oldestReview=f.all().filter(node=>node.type==='button'&&nodeText(node)==='aiGroupDraft.review').at(-1);
  oldestReview.props.onClick();await flush();
  f.all().find(node=>node.type==='textarea').props.onInput('Older edit');
  await flush();
  await f.click('common.refresh');
  assert.deepEqual(historyQueries().slice(-2),[{before_sequence:10000000000,limit:50},{after_sequence:0,limit:1}]);
  assert.match(f.text(),/aiGroupDraft.reviewRestored/);
  assert.equal(f.all().find(node=>node.type==='textarea').props.value,'Older edit');
});

test('saved group draft is recovered through read-only history refresh', async t => {
  const f = await fixture(t);
  f.state.historyUnavailable = true;
  await f.click('aiGroupDraft.generate');
  assert.match(f.text(), /aiGroupDraft\.generationSaved/);
  assert.equal(f.button('aiGroupDraft.generate').props.disabled, true);
  f.state.historyUnavailable = false;
  await f.click('common.refresh');
  assert.match(f.text(), /Draft for review/);
  assert.equal(f.requests.filter(request=>request.path===generate).length,1);
});

test('earlier group draft pagination forgets a deleted conversation and keeps the search term', async t => {
  const f = await fixture(t);
  f.state.historySize = 53;
  await f.click('Weeklytoday');
  const search = f.all().find(node => node.type === 'input' && node.props.type === 'text');
  search.value = 'planned release';
  search.listeners.input({target:search});
  await flush();
  f.state.historyMissing = true;
  await f.click('chat.directMessage.loadOlder');
  assert.match(f.text(), /aiGroupDraft\.conversationMissing/);
  assert(!f.button('Weeklytoday'));
  assert.doesNotMatch(f.text(), /Draft sequence 53/);
  assert.equal(search.value, 'planned release');
  assert(!f.button('aiGroupDraft.generate').props.disabled);
  assert(!f.requests.some(request => request.options.method === 'POST'));
});

test('Web falls back to forward paging when the backend ignores before_sequence', async t => {
  const f = await fixture(t);
  f.state.historySize = 53;
  f.state.legacyCursor = true;
  await f.click('Weeklytoday');
  assert.deepEqual(f.requests.filter(r=>r.path===`${base}/${id}/messages`).map(r=>r.options.query),[
    {before_sequence:10000000000,limit:50}, {after_sequence:50,limit:50},
  ]);
  assert.match(f.text(),/Draft sequence 53\./);
  assert.doesNotMatch(f.text(),/Draft sequence 1\./);
  await f.click('chat.directMessage.loadOlder');
  assert.match(f.text(),/Draft sequence 1\./);
  assert(!f.button('chat.directMessage.loadOlder'));
});

test('Web displays the quota retry time and keeps restored drafts available',async t=>{
  const f=await fixture(t);
  f.state.generated=true;
  await f.click('Weeklytoday');
  f.state.retryAfter=30;
  await f.click('aiGroupDraft.generate');
  assert.match(f.text(),/aiGroupDraft\.quotaRetry:30/);
  assert.match(f.text(),/Draft for review/);
  assert.match(f.text(),/aiModelVersion · group-build-2/);
  assert.match(f.text(),/aiReplyConfigRevision:2/);
  assert.equal(f.requests.filter(request=>request.path===generate).length,1);
});

test('Web generation uses the expected sequence and publishing requires explicit review',async t=>{
  const f=await fixture(t);
  assert.doesNotMatch(f.text(),/Hidden data/);
  await f.click('aiGroupDraft.generate');
  assert.deepEqual(f.requests.find(r=>r.path===base&&r.options.method==='POST').options.body,{purpose:'group',group_id:7});
  assert.deepEqual(f.requests.find(r=>r.path===generate).options.body,{kind:'weekly_report',expected_sequence:0});
  assert.equal(f.publications.length,0);
  assert.match(f.text(),/Draft for review/);
  assert(f.all().some(node=>node.type==='a'&&node.props.to?.query?.post===24));
  assert(f.all().some(node=>node.type==='a'&&node.props.to?.query?.post===24&&node.props.to?.query?.comment===31));
  await f.click('aiGroupDraft.review');
  assert.equal(f.publications.length,0);
  const editor=f.all().find(node=>node.type==='textarea');
  editor.props.onInput('界'.repeat(1334));
  await flush();
  assert(f.button('aiGroupDraft.confirmPublish').props.disabled);
  assert.match(f.text(),/aiGroupDraft\.tooLong/);
  assert.equal(f.publications.length,0);
  editor.props.onInput('Reviewed text');
  await flush();
  await f.click('aiGroupDraft.confirmPublish');
  assert.deepEqual(f.publications,[{groupId:7,body:{content:'Reviewed text',is_announcement:false}}]);
  assert.match(f.text(),/aiGroupDraft\.published/);
});

test('Web reopens the current conversation and keeps an uncertain edit only for a current draft',async t=>{
  const f=await fixture(t);
  await f.click('aiGroupDraft.generate');
  await f.click('aiGroupDraft.review');
  const publish=f.state.publish;
  f.state.publish=async (groupId,body)=>({ ...await publish(groupId,body), is_announcement:!body.is_announcement });
  f.all().find(node=>node.type==='textarea').props.onInput('Preserved edit');
  await flush();
  await f.click('aiGroupDraft.confirmPublish');
  assert(f.button('aiGroupDraft.confirmPublish').props.disabled);
  const groupPosts = () => f.all().find(node => node.type === 'a' && nodeText(node) === 'aiGroupDraft.checkGroupPostsNewTab');
  assert.deepEqual(groupPosts()?.props.to, {path:'/groups/posts', query:{group:7}});
  assert.equal(groupPosts()?.props.target, '_blank');
  await f.click('Weeklytoday');
  assert.match(f.text(),/aiGroupDraft\.reviewRestored/);
  assert(groupPosts());
  assert.equal(f.all().find(node=>node.type==='textarea').props.value,'Preserved edit');
  assert(f.button('aiGroupDraft.confirmPublish').props.disabled);
  const retryLabel = f.all().find(node => node.type === 'label' && nodeText(node).includes('aiGroupDraft.confirmPublicationRetry'));
  const retry = descendants(retryLabel).find(node => node.type === 'input');
  retry.checked = true;
  retry.listeners.change();
  await flush();
  assert(!f.button('aiGroupDraft.confirmPublish').props.disabled);
  assert.equal(f.publications.length,1);
  await f.click('aiGroupDraft.confirmPublish');
  await f.click('common.refresh');
  assert.equal(f.publications.length,2);
  assert(f.button('aiGroupDraft.confirmPublish').props.disabled);
  f.state.sourceHidden=true;
  await f.click('common.refresh');
  assert(!f.all().some(node=>node.type==='textarea'));
  assert.equal(groupPosts(),undefined);
  assert.match(f.text(),/aiGroupDraft\.conflict/);
});

test('Web cancels the final publish request when the account changes',async t=>{
  const f=await fixture(t);
  await f.click('aiGroupDraft.generate');
  await f.click('aiGroupDraft.review');
  let finish;
  f.state.publish=()=>new Promise(resolve=>{finish=resolve;});
  await f.click('aiGroupDraft.confirmPublish');
  const post=f.requests.find(entry=>entry.path==='/api/v2/groups/7/posts');
  assert.equal(post.options.signal.aborted,false);
  authQueueFor(f.owner).beginIdentityChange();
  assert.equal(post.options.signal.aborted,true);
  finish({post_id:31,group_id:7,is_announcement:false});
  await flush();
  assert.doesNotMatch(f.text(),/aiGroupDraft\.published/);
});

test('Web sends the selected skill and validated search phrase',async t=>{
  const f=await fixture(t);
  const chooser=f.all().find(node=>node.type==='select' &&
    node.children.some(child=>child.props?.value==='group-brief'));
  assert(chooser);
  chooser.props['onUpdate:modelValue']('group-brief');
  const search=f.all().find(node=>node.type==='input' && node.props.type==='text');
  assert(search);
  search.value='猫'.repeat(86);
  search.listeners.input({target:search});
  await flush();
  assert(f.button('aiGroupDraft.generate').props.disabled);
  search.value=' 活动报名 ';
  search.listeners.input({target:search});
  await flush();
  await f.click('aiGroupDraft.generate');
  assert.deepEqual(f.requests.find(r=>r.path===generate).options.body,{
    kind:'weekly_report',expected_sequence:0,skill_id:'group-brief',search_term:'活动报名',
  });
});

test('Web panel rejects a draft when a source disappears before confirmation',async t=>{
  const f=await fixture(t);
  await f.click('aiGroupDraft.generate');
  await f.click('aiGroupDraft.review');
  f.state.sourceHidden=true;
  await f.click('aiGroupDraft.confirmPublish');
  assert.equal(f.publications.length,0);
  assert.doesNotMatch(f.text(),/Draft for review/);
  assert.match(f.text(),/aiGroupDraft\.conflict/);
});

test('Web history removal requires confirmation for the selected conversation',async t=>{
  const f=await fixture(t);
  await f.click('Weeklytoday');
  await f.click('aiGroupDraft.delete');
  assert.equal(f.requests.filter(r=>r.options.method==='DELETE').length,0);
  await f.click('aiGroupDraft.confirmDelete');
  const deletes=f.requests.filter(r=>r.options.method==='DELETE');
  assert.equal(deletes.length,1);
  assert.equal(deletes[0].path,`${base}/${id}`);
  assert.doesNotMatch(f.text(),/Weekly/);
});

test('Web cancels in-flight generation and removes previous data on identity change',async t=>{
  const f=await fixture(t);
  let finish;
  f.state.pending=new Promise(resolve=>{finish=resolve;});
  await f.click('aiGroupDraft.generate');
  const request=f.requests.find(r=>r.path===generate);
  assert(request);
  authQueueFor(f.owner).beginIdentityChange();
  assert.equal(request.options.signal.aborted,true);
  finish();
  await flush();
  assert.doesNotMatch(f.text(),/Draft for review|Weekly/);
  assert.match(f.text(),/aiGroupDraft\.sessionChanged/);
  assert.equal(f.publications.length,0);
});
