import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { compileScript, parse } from '@vue/compiler-sfc';
import { build } from 'esbuild';
import { createRenderer, h, proxyRefs, reactive } from 'vue';

const filename = 'TweetComposer.vue';
const source = readFileSync(new URL('../app/components/TweetComposer.vue', import.meta.url), 'utf8');
const { descriptor } = parse(source, { filename });
const { content } = compileScript(descriptor, { id: 'composer-fixture' });
const compiled = await build({
  stdin: { contents: content, loader: 'ts' },
  bundle: true, write: false, platform: 'node', format: 'esm',
  plugins: [{ name: 'composer-boundaries', setup(builder) {
    builder.onResolve({ filter: /^(vue|lucide-vue-next)$/ }, args => ({
      path: import.meta.resolve(args.path), external: true
    }));
    builder.onResolve({ filter: /.*/ }, args => ({ path: args.path, namespace: 'fixture' }));
    builder.onLoad({ filter: /.*/, namespace: 'fixture' }, args => {
      const fixture = 'globalThis.__composeMediaFixture';
      const stubs = {
        'vue-sonner': `export const toast = { error: message => ${fixture}.errors.push(message) };`,
        '@/stores/user': `export const usePreferenceStore = () => ${fixture}.preferences;`,
        '@/services/auth-request-queue': `export const authQueueFor = () => ({revision: 0, subscribe: () => () => {}});`,
        '@/utils/private-media': 'export const isPrivateMediaContent = () => false;',
        '@/api/v2/posts': `export const v2UploadMedia = form => ${fixture}.upload(form);
          export const v2DeleteMedia = id => ${fixture}.remove(id);`
      };
      const names = Array.from(content.matchAll(/import\s*\{([^}]+)\}\s*from\s*['"]([^'"]+)['"]/g))
        .find(match => match[2] === args.path)?.[1]?.split(',').map(name => name.trim()).filter(Boolean) ?? [];
      return { contents: stubs[args.path] ?? (
        args.path.endsWith('.vue') ? 'export default {};' : names.map(name => `export const ${name} = {};`).join('\n')
      ) };
    });
  }}]
});
const { default: Composer } = await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);

test('partial upload retry reuses IDs and only confirmed deletion removes the draft', async () => {
  const uploads = [], removals = [], submitted = [], errors = [];
  const preferences = reactive({ isLoggedIn: true, preferences: { user: { id: 1 }, authSession: { sessionId: 'old' } } });
  let failUpload = true, conflict = true;
  globalThis.useAppLocale = () => ({ t: key => key });
  globalThis.useNuxtApp = () => ({});
  globalThis.__composeMediaFixture = {
    preferences, errors,
    async upload(form) {
      const file = form.get('file');
      uploads.push(file.name);
      if (file.name === 'second.png' && failUpload) throw new Error('upload failed');
      return { media_id: file.name === 'first.png' ? 11 : 12, public_url: `/storage/${file.name}` };
    },
    async remove(id) {
      removals.push(id);
      if (conflict) throw Object.assign(new Error('in use'), { statusCode: 409 });
    }
  };
  let state;
  const renderer = createRenderer({ insert() {}, remove() {}, createComment() { return {}; }, parentNode() { return {}; } });
  const app = renderer.createApp({
    render: () => h({ ...Composer, render: () => null, setup(props, context) {
      state = proxyRefs(Composer.setup(props, context));
      return state;
    } }, {
      initialDraft: 'Editable AI draft',
      onSubmit: form => submitted.push(form.mediaIds)
    })
  });
  app.mount({});
  try {
    assert.equal(state.tweetContent, 'Editable AI draft');
    state.appendMediaFiles(['first.png', 'second.png'].map(name => new File(['fixture'], name, { type: 'image/png' })));
    await state.handleSubmit();
    assert.deepEqual(uploads, ['first.png', 'second.png']);
    assert.deepEqual(submitted, []);
    failUpload = false;
    await state.handleSubmit();
    assert.deepEqual(uploads, ['first.png', 'second.png', 'second.png']);
    assert.deepEqual(submitted, [[11, 12]]);
    await state.removeMedia(state.mediaDrafts[0]);
    assert.deepEqual(state.mediaDrafts.map(item => item.mediaId), [11, 12]);
    assert.equal(errors.at(-1), 'post.composer.mediaInUse');
    conflict = false;
    await state.removeMedia(state.mediaDrafts[0]);
    assert.deepEqual(removals, [11, 11]);
    assert.deepEqual(state.mediaDrafts.map(item => item.mediaId), [12]);
    preferences.preferences.authSession = { sessionId: 'new' };
    assert.deepEqual(state.mediaDrafts, []);
    assert.equal(state.tweetContent, '');
  } finally {
    app.unmount();
    delete globalThis.useAppLocale;
    delete globalThis.useNuxtApp;
    delete globalThis.__composeMediaFixture;
  }
});
