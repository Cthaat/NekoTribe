import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { parse } from '@vue/compiler-sfc';
import { transform } from 'esbuild';
import { ref } from 'vue';

const page = readFileSync(new URL('../app/pages/moderation/settings.vue', import.meta.url), 'utf8');
const script = parse(page).descriptor.scriptSetup.content.replace(/^import[\s\S]*? from ['"][^'"]+[''];\r?\n/gm, '');
const {code} = await transform(script, {loader:'ts'});
const fixture = new Function('ref','getModerationSettings','updateModerationSettings', `
  const useAppLocale = () => ({t:key=>key});
  const useNuxtApp = () => ({});
  const toast = {success(){},error(){}};
  let mounted, observe;
  const onMounted = callback => { mounted = callback; };
  const onUnmounted = () => {};
  const fakeQueue = {revision:0,isIdentityChanging:false,subscribe: callback => { observe=callback; }};
  const authQueueFor = () => fakeQueue;
  ${code}
  mounted();
  return {settings,saveSettings,changeOwner(){fakeQueue.revision++;observe();}};
`);

test('moderation settings submits only locally edited values and applies the server snapshot', async () => {
  const base = [{key:'default_mute_hours',value:'24'},{key:'require_note_on_reject',value:'true'}];
  let writes = 0;
  const view = fixture(ref,async () => structuredClone(base),async items => {
    writes++;
    assert.deepEqual(items,[{key:'default_mute_hours',value:'0036'}]);
    return [{key:'default_mute_hours',value:'36'},{key:'require_note_on_reject',value:'false'}];
  });
  await Promise.resolve();
  await view.saveSettings();
  assert.equal(writes,0);
  view.settings.value[0].value='0036';
  await view.saveSettings();
  assert.equal(writes,1);
  assert.deepEqual(view.settings.value.map(item => item.value),['36','false']);
  view.settings.value[0].value='77';
  view.changeOwner();
  await view.saveSettings();
  assert.equal(writes,1);
  assert.deepEqual(view.settings.value,[]);
});

test('a settings response from the previous session is ignored', async () => {
  let complete;
  const view = fixture(ref, () => new Promise(resolve => { complete=resolve; }), async () => {
    assert.fail('submitted stale settings');
  });
  view.changeOwner();
  complete([{key:'default_mute_hours',value:'24'}]);
  await Promise.resolve();
  await view.saveSettings();
  assert.deepEqual(view.settings.value,[]);
});
