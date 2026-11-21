import assert from 'node:assert/strict';
import { test } from 'node:test';
import { build } from 'esbuild';
import { fileURLToPath } from 'node:url';
import { readFileSync } from 'node:fs';

const root = fileURLToPath(new URL('../', import.meta.url));
const vectors = JSON.parse(readFileSync(new URL('../specifications/scenarios/ai-availability-client-vectors.json', import.meta.url), 'utf8'));
const built = await build({
  stdin: { contents: `export * from './app/services/ai-writing-controller'; export {writingApi} from './app/api/v2/ai-writing'; export {knowledgeApi} from './app/api/v2/ai-knowledge';`, resolveDir: root, loader: 'ts' },
  bundle: true, write: false, platform: 'node', format: 'esm',
  plugins: [{ name: 'availability-network', setup(builder) {
    builder.onResolve({ filter: /^\.\/client$/ }, () => ({ path: 'client', namespace: 'stub' }));
    builder.onLoad({ filter: /.*/, namespace: 'stub' }, () => ({ contents: `export async function v2RequestData(path,options){globalThis.__availabilityCalls.push({path,options});return globalThis.__availabilityResult;}`, loader: 'js' }));
  } }]
});
const { createWritingController, initialWritingState, writingApi, knowledgeApi } = await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);

function fixture(purpose = 'writing') {
  const state = initialWritingState();
  state.draft = 'my unsent draft';
  state.searchPhrase = '猫';
  const calls = [];
  let flags = { knowledge: true, writing: true };
  const api = {
    availability: async () => flags,
    create: async () => { calls.push('create'); return { conversation_id: 'id' }; },
    read: async id => ({ conversation_id: id, purpose }),
    append: async () => { calls.push('append'); return 1; },
    generate: async () => { calls.push('generate'); return { status: 'generated' }; },
    messages: async () => [{ message_id: 'u', sequence_no: 1, role: 'user', content: 'previous' }],
    list: async () => ({ items: [{ conversation_id: 'id', purpose }], next_cursor: null }),
    remove: async () => { calls.push('remove'); }
  };
  return { state, calls, api, setFlags: value => { flags = value; }, controller: createWritingController(api, state, purpose) };
}

test('initial unknown configuration cannot create or append a message', async () => {
  const f = fixture();
  assert.equal(f.state.availability, 'loading');
  await f.controller.send();
  assert.deepEqual(f.calls, []);
  assert.equal(f.state.draft, 'my unsent draft');
});

test('a missing model configuration blocks generation without blocking history', async () => {
  const f = fixture();
  f.setFlags({ knowledge: true, writing: true, inference: { knowledge: true, writing: false } });
  await f.controller.loadAvailability();
  assert.equal(f.state.availability, 'unconfigured');
  await f.controller.send();
  assert.deepEqual(f.calls, []);
  await f.controller.loadHistory();
  assert.equal(f.state.history.length, 1);
});

test('each purpose uses its own flag; refreshing retains draft and permits later generation', async () => {
  for (const purpose of ['knowledge', 'writing']) {
    const f = fixture(purpose);
    f.setFlags({ knowledge: purpose !== 'knowledge', writing: purpose !== 'writing' });
    await f.controller.loadAvailability();
    assert.equal(f.state.availability, 'disabled');
    await f.controller.send();
    assert.deepEqual(f.calls, []);
    assert.equal(f.state.draft, 'my unsent draft');
    assert.equal(f.state.searchPhrase, '猫');
    f.setFlags({ knowledge: true, writing: true });
    await f.controller.loadAvailability();
    assert.equal(f.state.availability, 'enabled');
    await f.controller.send();
    assert.deepEqual(f.calls, ['create', 'append', 'generate']);
  }
});

test('unavailable configuration blocks regeneration but permits history refresh and removal', async () => {
  const f = fixture();
  f.api.availability = async () => { throw Error('503'); };
  await f.controller.loadAvailability();
  assert.equal(f.state.availability, 'unknown');
  await f.controller.loadHistory();
  await f.controller.select('id');
  f.state.draft = 'keep while refreshing';
  await f.controller.retry();
  assert.deepEqual(f.calls, []);
  await f.controller.retry(false);
  assert.equal(f.state.messages[0].content, 'previous');
  assert.equal(f.state.draft, 'keep while refreshing');
  await f.controller.remove();
  assert.deepEqual(f.calls, ['remove']);
});

test('refresh discards stale enabled state and older responses cannot overwrite newer results', async () => {
  const f = fixture();
  const writing = {id:'writing-draft',purpose:'writing',version:1,enabled:true};
  f.setFlags({knowledge:true,writing:true,skills:[writing],modelConfigRevision:7});
  await f.controller.loadAvailability();
  assert.deepEqual(f.state.skill, writing);
  assert.equal(f.state.modelConfigRevision, 7);
  let oldResolve;
  f.api.availability = () => new Promise(resolve => { oldResolve = resolve; });
  const older = f.controller.loadAvailability();
  assert.equal(f.state.availability, 'loading');
  assert.equal(f.state.skill, undefined);
  assert.equal(f.state.modelConfigRevision, undefined);
  await f.controller.send();
  assert.deepEqual(f.calls, []);
  const disabled = {...writing, version:2, enabled:false};
  f.api.availability = async () => ({ knowledge: false, writing: false, skills:[disabled],modelConfigRevision:9 });
  await f.controller.loadAvailability();
  oldResolve({ knowledge: true, writing: true, skills:[writing],modelConfigRevision:8 });
  await older;
  assert.equal(f.state.availability, 'disabled');
  assert.deepEqual(f.state.skill, disabled);
  assert.equal(f.state.modelConfigRevision, 9);
  assert.equal(f.state.draft, 'my unsent draft');
  f.controller.close();
  assert.equal(f.state.skill, undefined);
  assert.equal(f.state.modelConfigRevision, undefined);
});

test('both APIs use the shared route and reject missing or nonboolean flags', async () => {
  globalThis.__availabilityCalls = [];
  try {
    for (const api of [writingApi, knowledgeApi]) {
      for (const vector of vectors.cases) {
        globalThis.__availabilityResult = vector.data;
        if (vector.accepted) assert.deepEqual(await api.availability(), vector.expected, vector.id);
        else await assert.rejects(() => api.availability(), /availability/i, vector.id);
      }
    }
    assert(globalThis.__availabilityCalls.every(call => call.path === '/api/v2/ai/availability' && call.options?.method === 'GET'));
  } finally {
    delete globalThis.__availabilityCalls;
    delete globalThis.__availabilityResult;
  }
});

test('knowledge and writing only admit complete message pages for the requested conversation', async () => {
  const id = 'f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb';
  const first = {conversation_id:id,message_id:'reply',sequence_no:2,role:'assistant',content:'draft'};
  globalThis.__availabilityCalls = [];
  try {
    for (const client of [writingApi,knowledgeApi]) {
      globalThis.__availabilityResult = [first];
      assert.deepEqual(await client.messages(id,0,undefined,100),[first]);
      assert.equal(globalThis.__availabilityCalls.at(-1).path,`/api/v2/ai/conversations/${id}/messages`);
      assert.deepEqual(globalThis.__availabilityCalls.at(-1).options.query,{before_sequence:100,limit:50});
      for (const bad of [
        [{...first,conversation_id:undefined}],
        [first,{...first,conversation_id:'other',message_id:'second',sequence_no:3}],
        [first,{...first,sequence_no:3}],
        [{...first,message_id:''}],
        [{...first,sequence_no:10_000_000_000}],
      ]) {
        globalThis.__availabilityResult=bad;
        await assert.rejects(()=>client.messages(id,0),/invalid history message/);
      }
    }
  } finally {
    delete globalThis.__availabilityCalls;
    delete globalThis.__availabilityResult;
  }
});
