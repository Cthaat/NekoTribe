import assert from 'node:assert/strict';
import { test } from 'node:test';
import { build } from 'esbuild';
import { fileURLToPath } from 'node:url';
const root=fileURLToPath(new URL('../',import.meta.url));
const compiled=await build({stdin:{contents:`export * from './app/services/ai-writing-controller.ts'`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm'});
const {createWritingController,initialWritingState,citationTarget}=await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);
test('terms citations resolve only known local section paths and never as posts',()=>{
 assert.deepEqual(citationTarget({kind:'terms',id:3,version:'a'.repeat(64)}),{kind:'terms',href:`/zh/auth/terms?citation=3.${'a'.repeat(64)}#conduct`});
 assert.deepEqual(citationTarget({kind:'terms',id:8,version:'a'.repeat(64)}),{kind:'terms',href:`/en/auth/terms?citation=8.${'a'.repeat(64)}#termination`});
 assert.equal(citationTarget({kind:'terms',id:3,version:'a'.repeat(64)+'\n'}),null);
 assert.equal(citationTarget({kind:'terms',id:9,post_id:42,version:'a'.repeat(64)}),null);
 assert.deepEqual(citationTarget({kind:'comment',id:3,post_id:42,version:'a'.repeat(64)}),{kind:'post',id:42});
});
test('group citations retain both group and post and require valid location fields', () => {
  const source = {kind:'group_comment',id:21,post_id:11,group_id:7,version:'a'.repeat(64)};
  assert.deepEqual(citationTarget(source), {kind:'group',groupId:7,postId:11,commentId:21});
  assert.deepEqual(citationTarget({...source,kind:'group_post',id:11}), {kind:'group',groupId:7,postId:11});
  assert.equal(citationTarget({...source,group_id:undefined}), null);
  assert.equal(citationTarget({...source,post_id:undefined}), null);
  assert.equal(citationTarget({...source,kind:'group_post'}), null);
  assert.equal(citationTarget({...source,kind:'comment'}), null);
});
test('knowledge conversations show insufficient evidence without writing a reply',async()=>{
  const state=Object.assign(initialWritingState(), {availability:'enabled'});
  const messages=[];
  const api={async create(){return {conversation_id:'id'}},async append(id,content){messages.push({message_id:'u',sequence_no:1,role:'user',content});return 1;},async generate(){return {status:'insufficient_evidence',message:null}},async messages(id,after){return messages.filter(m=>m.sequence_no>after)},async list(){return {items:[{conversation_id:'id',purpose:'knowledge'},{conversation_id:'other',purpose:'writing'}],next_cursor:null}},async remove(){}};
  const controller=createWritingController(api,state,'knowledge');state.draft='猫';state.searchPhrase='猫';await controller.send();
  assert.equal(state.insufficientEvidence,true);assert.equal(state.refreshRequired,false);assert.equal(state.messages.length,1);
  await controller.loadHistory();assert.deepEqual(state.history.map(item=>item.conversation_id),['id']);
  controller.reset();assert.equal(state.insufficientEvidence,false);
});
test('knowledge history preserves citations and rejects malformed generation status',async()=>{
  const state=Object.assign(initialWritingState(), {availability:'enabled'});
  const citation={kind:'post',id:7,version:'a'.repeat(64)};
  const messages=[{message_id:'a',sequence_no:1,role:'assistant',content:'answer',citations:[citation]}];
  const api={async create(){return {conversation_id:'id'}},async read(id){return {conversation_id:id,purpose:'knowledge'}},async append(id,content){messages.push({message_id:'u',sequence_no:2,role:'user',content});return 2;},async generate(){return {status:'unexpected'}},async messages(id,after){return messages.filter(m=>m.sequence_no>after)},async list(){return {items:[],next_cursor:null}},async remove(){}};
  const controller=createWritingController(api,state,'knowledge');await controller.select('id');
  assert.deepEqual(state.messages[0].citations,[citation]);state.draft='question';state.searchPhrase='猫';await controller.send();
  assert.equal(state.error,'generation');assert.equal(state.refreshRequired,true);
});
test('rechecking saved sources hides unverified answers and only reads history', async () => {
  const previous = {message_id:'a', sequence_no:1, role:'assistant', content:'old answer',
    citations:[{kind:'post', id:7, version:'a'.repeat(64)}]};
  const state = Object.assign(initialWritingState(), {id:'id', messages:[previous], draft:'keep my question'});
  let fail = true;
  const requests = [];
  const api = {
    async messages(id, after) {
      requests.push([id, after]);
      if (fail) throw Error('offline');
      return [{message_id:'a', sequence_no:1, role:'assistant', content:'公开资料已变更，历史回答不可用。'}];
    }
  };
  const controller = createWritingController(api, state, 'knowledge');
  await controller.retry(false);
  assert.equal(state.refreshRequired, true);
  assert.equal(state.error,'history');
  assert.deepEqual(state.messages, []);
  fail = false;
  await controller.retry(false);
  assert.equal(state.refreshRequired, false);
  assert.equal(state.messages[0].citations, undefined);
  assert.match(state.messages[0].content, /历史回答不可用/);
  assert.equal(state.draft,'keep my question');
  assert.deepEqual(requests,[['id',0],['id',0]]);
});
test('knowledge client uses the shared contract and safely encodes conversation IDs',async()=>{
  const built=await build({stdin:{contents:`export {knowledgeApi} from './app/api/v2/ai-knowledge.ts'`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'stub',setup(b){b.onResolve({filter:/^\.\/client$/},()=>({path:'client',namespace:'stub'}));b.onLoad({filter:/.*/,namespace:'stub'},()=>({contents:`export async function v2RequestData(path,options){globalThis.__knowledgeCalls.push({path,options});return path.endsWith('/knowledge-generate')?{status:'insufficient_evidence',message:null}:{};}`,loader:'js'}))}}]});
  const {knowledgeApi}=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);
  const {signal} = new AbortController();
  globalThis.__knowledgeCalls=[];await knowledgeApi.create(signal);await knowledgeApi.generate('a/b','猫',signal);
  assert.deepEqual(globalThis.__knowledgeCalls,[{path:'/api/v2/ai/conversations',options:{signal,method:'POST',body:{purpose:'knowledge'}}},{path:'/api/v2/ai/conversations/a%2Fb/knowledge-generate',options:{signal,method:'POST',body:{search_phrase:'猫'}}}]);delete globalThis.__knowledgeCalls;
  globalThis.__knowledgeCalls=[];
  await knowledgeApi.generate('a/b','猫',signal,true,7);
  assert.deepEqual(globalThis.__knowledgeCalls[0].options.body,{search_phrase:'猫',skill_id:'knowledge-answer',expected_sequence:7});
  delete globalThis.__knowledgeCalls;
});
test('sends the question once and retries with the updated search phrase',async()=>{
  const state=Object.assign(initialWritingState(), {availability:'enabled'}), messages=[], phrases=[];let appends=0;
  const api={async create(){return {conversation_id:'id'}},async append(id,content){appends++;messages.push({message_id:'u',sequence_no:1,role:'user',content});return 1;},async generate(id,phrase){phrases.push(phrase);return {status:'insufficient_evidence',message:null}},async messages(id,after){return messages.filter(m=>m.sequence_no>after)},async list(){return {items:[],next_cursor:null}},async remove(){}};
  const controller=createWritingController(api,state,'knowledge');state.draft='社区里有什么猫？';state.searchPhrase=' 猫 ';await controller.send();
  state.searchPhrase='猫咪';await controller.retry();assert.equal(appends,1);assert.deepEqual(phrases,['猫','猫咪']);assert.equal(state.messages[0].content,'社区里有什么猫？');
});
test('invalid search phrase never appends the question',async()=>{
  const state=Object.assign(initialWritingState(), {availability:'enabled'});let calls=0;
  const api={async create(){calls++;return {conversation_id:'id'}},async append(){calls++},async generate(){},async messages(){return []},async list(){return {items:[],next_cursor:null}},async remove(){}};
  const controller=createWritingController(api,state,'knowledge');state.draft='问题';
  for(const term of ['', '猫\n咪', '猫'.repeat(86), '\ud800']){state.searchPhrase=term;await controller.send();assert.equal(state.error,'search-invalid');}
  assert.equal(calls,0);assert.equal(state.draft,'问题');
});
