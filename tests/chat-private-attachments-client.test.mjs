import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { compileScript, parse } from '@vue/compiler-sfc';
import { build } from 'esbuild';
import { effectScope, proxyRefs, reactive, ref } from 'vue';

async function compileComponent(path) {
  const source = readFileSync(new URL(path, import.meta.url), 'utf8');
  const { descriptor } = parse(source, { filename: path });
  const { content } = compileScript(descriptor, { id: path });
  const imports = [...content.matchAll(/import\s*\{([^}]+)\}\s*from\s*['"]([^'"]+)['"]/g)];
  const vue = import.meta.resolve('vue');
  const compiled = await build({
    stdin: { contents: content, loader: 'ts' },
    bundle: true,
    write: false,
    platform: 'node',
    format: 'esm',
    plugins: [{ name: 'channel-fixture', setup(builder) {
      builder.onResolve({ filter: /^file:/ }, args => ({ path: args.path, external: true }));
      builder.onResolve({ filter: /^@\/utils\/private-media$/ }, () => ({
        path: fileURLToPath(new URL('../app/utils/private-media.ts', import.meta.url))
      }));
      builder.onResolve({ filter: /.*/ }, args => ({ path: args.path, namespace: 'fixture' }));
      builder.onLoad({ filter: /.*/, namespace: 'fixture' }, ({ path }) => {
        const fixture = 'globalThis.__privateChatFixture';
        const stubs = {
          vue: `export * from ${JSON.stringify(vue)};
            export const onMounted = () => {};
            export const onBeforeUnmount = () => {};`,
          'vue-sonner': `export const toast = {
            error: message => ${fixture}.errors.push(message), success: () => {}
          };`,
          '@/stores/user': `export const usePreferenceStore = () => ${fixture}.store;`,
          '@/composables/useRealtimeSocket': `export const useRealtimeSocket = () => ${fixture}.realtime;`,
          '@/composables/useChatTyping': `export const useChatTyping = () => ({ stop() {}, edit() {}, receive() {}, reset() {} });`,
          '@/composables/useDirectMessageViewport': `export const useDirectMessageViewport = () => {};`,
          '@/composables/useWebRtcCalls': `export const useWebRtcCalls = () => ({});`
        };
        const custom = {
          v2UploadMedia: `(form, signal) => ${fixture}.upload(form, signal)`,
          v2CreateChatMessage: `(channel, payload) => ${fixture}.send(channel, payload)`,
          v2CreateDirectMessage: `(conversation, payload) => ${fixture}.send(conversation, payload)`,
          v2ListDirectConversations: `async () => ({ items: [], meta: { page: 1, has_next: false } })`,
          mapV2ChatMessage: 'message => ({ id: message.message_id })',
          mergeDirectMessages: '(messages, updates) => [...messages, ...updates]',
          replaceChatMessage: '(messages, message) => [...messages, message]'
        };
        const names = imports.find(match => match[2] === path)?.[1].split(',')
          .map(name => name.trim().split(/\s+as\s+/)[0]).filter(Boolean) ?? [];
        return {
          contents: stubs[path] ?? (path.endsWith('.vue') ? 'export default {};' :
            names.map(name => `export const ${name} = ${custom[name] ?? '{}'};`).join('\n'))
        };
      });
    }}]
  });
  const url = `data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`;
  return (await import(url)).default;
}

const [ChatPage, ChatInput, ChatMessage, ChatSearchFilters] = await Promise.all([
  compileComponent('../app/pages/chat.vue'),
  compileComponent('../app/components/ChatInput.vue'),
  compileComponent('../app/components/ChatMessage.vue'),
  compileComponent('../app/components/ChatSearchFilters.vue'),
]);
const setupContext = { expose() {}, emit() {} };
const media = id => ({ media_id: id, public_url: `/api/v2/media/${id}/content`, thumbnail_url: null });

test('channel composer rejects invalid batches and preserves selected files', t => {
  globalThis.useAppLocale = () => ({ t: key => key });
  const scope = effectScope();
  t.after(() => scope.stop());
  const composer = scope.run(() => proxyRefs(ChatInput.setup({
    sendMessage: async () => true
  }, setupContext)));
  const draft = new File(['draft'], 'draft.txt');
  const image = new File(['image'], 'photo.png', { type: 'image/png' });
  function pick(files, imagesOnly = false) {
    const target = { value: 'selected', files };
    const handler = imagesOnly ? composer.handleImageSelect : composer.handleFileSelect;
    handler({ target });
    assert.equal(target.value, '');
  }

  pick([draft]);
  pick(Array(32).fill(image), true);
  assert.equal(composer.attachmentError, 'chat.composer.attachmentCount');
  pick([image, { size: 500 * 1024 * 1024 + 1 }]);
  assert.equal(composer.attachmentError, 'chat.composer.attachmentSize');
  pick([new File([], 'empty.txt')]);
  assert.equal(composer.attachmentError, 'chat.composer.attachmentEmpty');
  assert.deepEqual(composer.attachments, [draft]);
  pick([image]);
  assert.equal(composer.attachmentError, '');
  assert.deepEqual(composer.attachments, [draft, image]);
});

test('message search combines keyword, sender and both local dates, and can clear the results', t => {
  globalThis.useAppLocale = () => ({ t: key => key });
  const scope = effectScope();
  t.after(() => scope.stop());
  const events = [];
  const form = scope.run(() => proxyRefs(ChatSearchFilters.setup({senders:[{id:43,label:'Peer'}]}, {
    ...setupContext, emit: (name, value) => events.push([name,value]),
  })));
  form.keyword = '  team  ';
  form.sender = 43;
  form.start = form.end = '2026-09-21';
  form.submit();
  assert.deepEqual(events,[['search',{q:'team',sender_id:43,
    start_at:new Date('2026-09-21T00:00:00').toISOString(),end_at:new Date('2026-09-22T00:00:00').toISOString()}]]);
  form.end = '2026-09-20';
  form.submit();
  assert.equal(form.error,'rangeError');
  assert.equal(events.length,1);
  form.clear();
  assert.deepEqual(events.at(-1),['search',null]);
});

test('a private composer sends attachment-only replies and cancels uploads after leaving', async t => {
  const { fixture, state } = channelFixture(t);
  const file = new File(['fixture'], 'photo.png', { type: 'image/png' });
  const sent = [];
  fixture.upload = async form => {
    assert.equal(form.get('access_scope'), 'chat');
    return media(11);
  };
  fixture.send = async (conversation, payload) => {
    sent.push([conversation, payload]);
    return { message_id: 60, conversation_id: conversation, author: { user_id: 42 }, content: '', media: [media(11)] };
  };
  state.directMessageTargetId = 43;
  state.directConversationId = 8;
  assert.equal(await state.handleSendDirectMessage(43, '', [file], 55), true);
  assert.deepEqual(sent, [[8, { content: '', media_ids: [11], reply_to_message_id: 55 }]]);
  assert.equal(state.directMessages[0].message_id, 60);
  let finish, signal;
  fixture.upload = (_form, request) => new Promise(resolve => { finish = resolve; signal = request; });
  const pending = state.handleSendDirectMessage(43, '', [file]);
  state.exitDirectMessageView();
  assert(signal.aborted);
  finish(media(12));
  assert.equal(await pending, false);
  assert.equal(sent.length, 1);
});

function channelFixture(t) {
  const preferences = reactive({ user: { id: 42 }, authSession: { sessionId: 'session' } });
  const fixture = {
    errors: [],
    store: { preferences, authRevision: () => 0, isAuthCurrent: revision => revision === 0 },
    realtime: { serverReady: ref(false), ownerRevision: ref(0), recoveryRevision: ref(0) }
  };
  globalThis.__privateChatFixture = fixture;
  globalThis.definePageMeta = () => {};
  globalThis.useAppLocale = () => ({ t: key => key });
  globalThis.useLocalePath = () => value => value;
  globalThis.useRoute = () => ({ query: {} });
  globalThis.useRouter = () => ({});
  globalThis.useNuxtApp = () => ({ runWithContext: work => work() });
  const scope = effectScope();
  t.after(() => scope.stop());
  const state = scope.run(() => proxyRefs(ChatPage.setup({}, setupContext)));
  state.activeChannel = { id: 7, type: 'text' };
  return { fixture, state };
}

test('channel retries reuse confirmed private upload IDs and reject mismatched receipts', async t => {
  const { fixture, state } = channelFixture(t);
  const first = new File(['one'], 'one.txt'), second = new File(['two'], 'two.txt');
  const uploaded = [], sent = [];
  let uploadAttempts = 0;
  fixture.upload = async form => {
    assert.equal(form.get('access_scope'), 'chat');
    const file = form.get('file');
    uploaded.push(file.name);
    if (file.name === second.name) {
      uploadAttempts++;
      if (uploadAttempts === 1) return { ...media(12), public_url: '/storage/public.txt' };
      if (uploadAttempts === 2) return { ...media(12), thumbnail_url: '/storage/sensitive.png' };
    }
    return media(file.name === first.name ? 11 : 12);
  };
  fixture.send = async (channel, payload) => {
    sent.push(payload);
    if (sent.length === 1) throw new Error('uncertain send');
    return { channel_id: sent.length === 2 ? channel + 1 : channel, message_id: 99,
      author: { user_id: 42 }, media: [media(11), media(12)] };
  };

  assert.equal(await state.handleSendMessage('hello', [first, second], 3), false);
  assert.equal(sent.length, 0);
  assert.equal(await state.handleSendMessage('hello', [first, second], 3), false);
  assert.equal(sent.length, 0);
  assert.equal(await state.handleSendMessage('hello', [first, second], 3), false);
  assert.equal(await state.handleSendMessage('hello', [first, second], 3), false);
  assert.equal(await state.handleSendMessage('hello', [first, second], 3), true);
  assert.deepEqual(uploaded, ['one.txt', 'two.txt', 'two.txt', 'two.txt']);
  assert.deepEqual(sent.map(item => [item.media_ids, item.reply_to_message_id]), [[[11, 12], 3], [[11, 12], 3], [[11, 12], 3]]);
});

test('channel and session changes discard stale upload receipts', async t => {
  const { fixture, state } = channelFixture(t);
  const file = new File(['fixture'], 'file.txt');
  let finishOld, uploadSignal;
  fixture.upload = (_form, signal) => new Promise(resolve => { finishOld = resolve; uploadSignal = signal; });
  const sends = [];
  fixture.send = async (channel, payload) => {
    sends.push(payload.media_ids);
    throw new Error('send failed');
  };
  const stale = state.handleSendMessage('hello', [file]);
  state.activeChannel = { id: 9, type: 'text' };
  state.activeChannel = { id: 7, type: 'text' };
  assert.equal(uploadSignal.aborted, true);
  finishOld(media(11));
  assert.equal(await stale, false);
  assert.deepEqual(sends, []);
  fixture.upload = async () => media(12);
  assert.equal(await state.handleSendMessage('hello', [file]), false);
  fixture.store.preferences.authSession = { sessionId: 'new' };
  fixture.upload = async () => media(13);
  assert.equal(await state.handleSendMessage('hello', [file]), false);
  assert.deepEqual(sends, [[12], [13]]);
});

test('channel composer keeps its draft on failure and separates private rendering', async t => {
  globalThis.useAppLocale = () => ({ t: key => key });
  const scope = effectScope();
  t.after(() => scope.stop());
  let success = false;
  const composer = scope.run(() => proxyRefs(ChatInput.setup({
    sendMessage: async () => success
  }, setupContext)));
  const file = new File(['fixture'], 'file.txt');
  composer.message = 'draft';
  composer.attachments = [file];
  await composer.handleSend();
  assert.equal(composer.message, 'draft');
  assert.deepEqual(composer.attachments, [file]);
  success = true;
  await composer.handleSend();
  assert.equal(composer.message, '');
  assert.deepEqual(composer.attachments, []);
  const state = scope.run(() => proxyRefs(ChatMessage.setup({
    message: { attachments: [
      { id: 11, type: 'image', url: '/api/v2/media/11/content' },
      { id: 12, type: 'file', url: '/api/v2/media/12/content' },
      { id: 13, type: 'image', url: '/storage/image.png' },
      { id: 14, type: 'file', url: '/storage/file.txt' }
    ] }
  }, setupContext)));
  assert.deepEqual(state.privateAttachments.map(item => item.id), [11, 12]);
  assert.deepEqual(state.publicImages.map(item => item.id), [13]);
  assert.deepEqual(state.publicFiles.map(item => item.id), [14]);
});
