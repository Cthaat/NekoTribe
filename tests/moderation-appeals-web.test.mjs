import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { parse } from '@vue/compiler-sfc';
import { transform } from 'esbuild';
import { ref, computed } from 'vue';

const page = readFileSync(new URL('../app/pages/moderation/reports.vue',import.meta.url),'utf8');
const source = parse(page).descriptor.scriptSetup.content.replace(/^import[\s\S]*? from ['"][^'"]+[''];\r?\n/gm,'');
const {code} = await transform(source,{loader:'ts'});
const fixture = new Function('ref','computed','listModerationAppeals','updateModerationAppeal',
  'listModerationReports','updateModerationReportStatus',`
  const useAppLocale = () => ({t:key=>key});
  const useNuxtApp = () => ({});
  const messages = [];
  const toast = {success: key=>messages.push(key), error: key=>messages.push(key)};
  let observe;
  const authQueueFor = () => fakeQueue;
  const fakeQueue = {revision:0, isIdentityChanging:false, subscribe: listener=>{observe=listener;return ()=>{};}};
  const watch = () => {};
  const onMounted = () => {};
  const onUnmounted = () => {};
  ${code}
  return {loadAppeals,openDecision,submitDecision,appeals,reply,decision,expired,messages,
    loadReports,setReportStatus,reports,filters,evidenceHref,
    changeOwner(){fakeQueue.revision++;observe();}};
`);

const pending = {id:12,status:'pending'};

test('legacy evidence is only linked when it is a site path or HTTP URL', () => {
  const {evidenceHref} = fixture(ref, computed);
  assert.equal(evidenceHref('/zh/tweet/30'), '/zh/tweet/30');
  assert.equal(evidenceHref('https://example.test/a'), 'https://example.test/a');
  for (const value of ['javascript:example', '//example.test', '/\\example.test', 'https://\nexample.test']) {
    assert.equal(evidenceHref(value), undefined);
  }
});

test('web submits the shared report body through the current identity', async () => {
  const source = readFileSync(new URL('../app/api/v2/moderation.ts', import.meta.url), 'utf8')
    .replace(/^import[\s\S]*? from ['"][^'"]+[''];\r?\n/gm,'')
    .replace(/^export /gm,'');
  const {code} = await transform(source, {loader:'ts'});
  const submit = new Function('v2RequestData', 'currentSessionMutation', code+'\nreturn v2CreateReport;');
  const payload = {target_type:'group_post', target_id:30, reason:'spam', description:'Detail'};
  let current = false;
  const result = await submit(async (path, options) => {
    assert.equal(current, true);
    assert.equal(path, '/api/v2/reports');
    assert.deepEqual(options, {method:'POST', body:payload});
    return {report_id:15};
  }, action => {current = true; return action();})(payload);
  assert.equal(result.report_id, 15);
});

test('report queue passes filters and renders the reopened report from the service', async () => {
  const resolved = {id:12,status:'resolved',resolvedAt:'2026-11-16T01:00:00.000Z'};
  const reopened = {id:12,status:'pending',resolvedAt:null};
  const view = fixture(ref,computed,undefined,undefined,async query => {
    assert.deepEqual(query,{status:'all',reason:'spam',targetType:'post',page:1,pageSize:20});
    return {items:[resolved],hasNext:false,page:1};
  },async (id,status) => {
    assert.deepEqual([id,status],[12,'pending']);
    return reopened;
  });
  view.filters.value = {status:'all',reason:'spam',targetType:'post'};
  await view.loadReports();
  await view.setReportStatus(view.reports.value[0],'pending');
  assert.deepEqual(view.reports.value,[reopened]);
});

test('stale decision refreshes the list when another moderator has decided', async () => {
  let reads=0;
  const view=fixture(ref,computed,async query=>{
    assert.deepEqual(query,{status:'pending',page:1,pageSize:10});
    return {items:reads++ ? [] : [pending],hasNext:false,page:1};
  },async(id,status,reply)=>{
    assert.deepEqual([id,status,reply],[12,'approved','Reviewed']);
    throw Object.assign(new Error('Conflict'),{statusCode:409});
  });
  await view.loadAppeals();
  view.openDecision(view.appeals.value[0],'approved');
  view.reply.value=' Reviewed ';
  await view.submitDecision();
  assert.equal(reads,2);
  assert.deepEqual(view.appeals.value,[]);
  assert.equal(view.decision.value,null);
  assert.deepEqual(view.messages,['moderation.appeals.handled']);
});

test('a moderator session change clears open decisions and received appeal rows', async () => {
  let writes=0;
  const view=fixture(ref,computed,async()=>({items:[pending],hasNext:false,page:1}),async()=>{writes++;});
  await view.loadAppeals();
  view.openDecision(view.appeals.value[0],'approved');
  view.reply.value='review draft';
  view.changeOwner();
  await view.submitDecision();
  assert.equal(writes,0);
  assert.equal(view.reply.value,'');
  assert.equal(view.decision.value,null);
  assert.deepEqual(view.appeals.value,[]);
  assert.equal(view.expired.value,true);
});
