import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { parse } from '@vue/compiler-sfc';
import { transform } from 'esbuild';
import {ref} from 'vue';

const page=readFileSync(new URL('../app/pages/moderation/users.vue',import.meta.url),'utf8');
const source=parse(page).descriptor.scriptSetup.content.replace(/^import[\s\S]*? from ['"][^'"]+[''];\r?\n/gm,'');
const {code}=await transform(source,{loader:'ts'});
const fixture=new Function('ref','listModerationUsers','moderateUser',`
  let mounted, listener;
  const fakeQueue={revision:0,isIdentityChanging:false,subscribe:callback=>{listener=callback;}};
  const authQueueFor=()=>fakeQueue;
  const useNuxtApp=()=>({});
  const useAppLocale=()=>({t:key=>key});
  const toast={error(){},success(){}};
  const watch=()=>{};
  const onMounted=fn=>{mounted=fn;};
  const onUnmounted=()=>{};
  ${code}
  mounted();
  return {users,filters,loadUsers,applyUserAction,changeOwner(){fakeQueue.revision++;listener();}};
`);
test('a stale filter result cannot replace a newer user queue or survive account switching', async()=>{
  const calls=[];
  const screen=fixture(ref, input=>new Promise(resolve=>calls.push({input,resolve})), async()=>assert.fail('sent a stale action'));
  screen.filters.value={q:'reader%',status:'active',sort:'reports'};
  const pending=screen.loadUsers();
  assert.deepEqual(calls[1].input,{q:'reader%',status:'active',sort:'reports',page:1,pageSize:20});
  calls[1].resolve({items:[{id:7,email:'review@example.test'}],page:1,hasNext:false});
  await pending;
  calls[0].resolve({items:[{id:42}],page:1,hasNext:false});
  await Promise.resolve();
  assert.equal(screen.users.value[0].id,7);
  const user=screen.users.value[0];
  screen.changeOwner();
  assert.deepEqual(screen.users.value,[]);
  await screen.applyUserAction(user,'ban');
});

test('Web leaves mute duration to backend moderation settings', async()=>{
  let request;
  const user={id:7,status:'active'};
  const screen=fixture(ref,async()=>({items:[user],page:1,hasNext:false}),async(id,action,options)=>{
    request={id,action,options};
    return {...user,activeRestriction:'mute'};
  });
  await screen.loadUsers();
  await screen.applyUserAction(screen.users.value[0],'mute');
  assert.deepEqual(request,{id:7,action:'mute',options:{reason:'moderation.users.defaultReason'}});
});
