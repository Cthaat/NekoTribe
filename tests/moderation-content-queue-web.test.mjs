import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {test} from 'node:test';
import {parse} from '@vue/compiler-sfc';
import {transform} from 'esbuild';
import {computed,ref} from 'vue';

const page=readFileSync(new URL('../app/pages/moderation/content.vue',import.meta.url),'utf8');
const source=parse(page).descriptor.scriptSetup.content.replace(/^import[\s\S]*? from ['"][^'"]+[''];\r?\n/gm,'');
const {code}=await transform(source,{loader:'ts'});
const fixture=new Function('ref','computed','listModerationContent','moderatePost','v2BulkModeratePosts',`
  let mounted,observe;
  const fakeQueue={revision:0,isIdentityChanging:false,subscribe:fn=>{observe=fn;}};
  const authQueueFor=()=>fakeQueue;
  const usePreferenceStore=()=>({preferences:{user:{id:7}}});
  const useNuxtApp=()=>({});
  const useAppLocale=()=>({t:key=>key});
  const toast={error(){},info(){},success(){}};
  const watch=()=>{};
  const onMounted=fn=>{mounted=fn;};
  const onUnmounted=()=>{};
  const getModerationStats=async()=>({pending:3});
  ${code}
  mounted();
  return {tweets,filters,loadContent,handleViewDetail,handleReject,applyPostAction,selectedTweet,detailModalOpen,
    selectedIds,toggleBulkSelection,openBulkDialog,submitBulkAction,bulkOpen,bulkNote,handleAssignment,
    changeOwner(){fakeQueue.revision++;observe();}};
`);

test('Web claims unassigned cases and releases only the current reviewer’s cases', async () => {
  let assignedTo;
  const calls = [];
  const screen = fixture(ref,computed,async()=>({items:[{id:81,status:'pending',assignedTo},{id:82,status:'pending',assignedTo:{id:8}}],page:1,hasNext:false}),
    async(id,action)=>{
      calls.push([id,action]);
      assignedTo = action === 'claim' ? {id:7} : undefined;
      return {id,status:'pending',assignedTo};
    });
  await screen.loadContent();
  screen.handleAssignment(82,'release');
  screen.handleAssignment(81,'claim');
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(screen.tweets.value[0].assignedTo,{id:7});
  screen.handleAssignment(81,'release');
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(calls,[[81,'claim'],[81,'release']]);
  assert.equal(screen.tweets.value[0].assignedTo,undefined);
});

test('Web batches selected post IDs and keeps the note after rejection', async () => {
  const submitted = [];
  const screen = fixture(ref,computed,async()=>({items:[{id:81},{id:82}],page:1,hasNext:false}),undefined,
    async payload => {
      submitted.push(payload);
      if (submitted.length === 1) throw new Error('moderation configuration rejected action');
      return {processed_count:2};
    });
  await screen.loadContent();
  screen.toggleBulkSelection(81);
  screen.toggleBulkSelection(82);
  screen.toggleBulkSelection(99);
  screen.openBulkDialog();
  screen.bulkNote.value = ' Reviewed ';
  assert.equal(submitted.length, 0);
  await screen.submitBulkAction();
  assert.equal(screen.bulkOpen.value, true);
  assert.equal(screen.bulkNote.value, ' Reviewed ');
  assert.deepEqual(submitted[0], {post_ids:[81,82],action:'flag',note:'Reviewed'});
  await screen.submitBulkAction();
  assert.equal(screen.bulkOpen.value, false);
  assert.equal(screen.selectedIds.value.size, 0);
  screen.toggleBulkSelection(81);
  screen.openBulkDialog();
  screen.changeOwner();
  await screen.submitBulkAction();
  assert.equal(submitted.length, 2);
});

test('Web opens rejection details and preserves the modal after validation failure', async()=>{
  const submitted=[];
  const item={id:81};
  const screen=fixture(ref,computed,async()=>({items:[item],page:1,hasNext:false}),
    async(id,verb,note)=>{
      submitted.push({id,verb,note});
      if (!note) throw new Error('notes required');
      return {...item,status:'rejected'};
    });
  await screen.loadContent();
  screen.handleReject(81);
  assert.equal(screen.detailModalOpen.value,true);
  assert.deepEqual(submitted,[]);
  await screen.applyPostAction(81,'reject');
  assert.equal(screen.detailModalOpen.value,true);
  await screen.applyPostAction(81,'reject','Reviewed');
  assert.equal(screen.detailModalOpen.value,false);
  assert.deepEqual(submitted,[{id:81,verb:'reject',note:''},{id:81,verb:'reject',note:'Reviewed'}]);
});

test('Web forwards priority and search, ignores prior results and closes stale case details',async()=>{
  const pending=[];
  const screen=fixture(ref,computed,input=>new Promise(resolve=>pending.push({input,resolve})));
  screen.filters.value={search:'text%',priority:'high',status:'pending',reportReason:'spam',dateRange:'week',sortBy:'most_reports'};
  const read=screen.loadContent(true);
  assert.deepEqual(pending[1].input,{q:'text%',status:'pending',priority:'high',reason:'spam',dateRange:'week',sort:'most_reports',page:1,pageSize:10});
  pending[1].resolve({items:[{id:81}],page:1,hasNext:false});
  await read;
  pending[0].resolve({items:[{id:82}],page:1,hasNext:false});
  await Promise.resolve();
  assert.deepEqual(screen.tweets.value,[{id:81}]);
  screen.handleViewDetail(screen.tweets.value[0]);
  assert.equal(screen.detailModalOpen.value,true);
  screen.changeOwner();
  assert.deepEqual(screen.tweets.value,[]);
  assert.equal(screen.selectedTweet.value,null);
  assert.equal(screen.detailModalOpen.value,false);
});
