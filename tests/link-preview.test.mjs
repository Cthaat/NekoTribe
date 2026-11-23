import assert from 'node:assert/strict';
import { Readable } from 'node:stream';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';
import { firstPreviewUrl } from '../app/utils/link-preview.ts';
import { firstMarkdownPreviewUrl } from '../app/utils/render-post-markdown.ts';

const { outputFiles } = await build({
  entryPoints: [fileURLToPath(new URL('../server/services/v2/link-preview.ts', import.meta.url))],
  bundle: true, write: false, platform: 'node', format: 'esm',
  plugins: [{ name: 'preview-network-fixture', setup(builder) {
    const fixtures = {
      '../../utils/redis': 'export const getRedisClient = () => null;',
      '../../utils/v2': 'export const v2BadRequest = () => { throw Object.assign(new Error(), {statusCode:400}); };',
      'node:http': 'export const request = (...args) => globalThis.previewTransport(...args);',
      'node:https': 'export const request = (...args) => globalThis.previewTransport(...args);',
    };
    builder.onResolve({ filter: /.*/ }, ({ path }) => Object.hasOwn(fixtures, path) ? { path, namespace: 'fixture' } : undefined);
    builder.onLoad({ filter: /.*/, namespace: 'fixture' }, ({ path }) => ({ contents: fixtures[path] }));
  } }],
});
const { createLinkPreviewService } = await import(`data:text/javascript;base64,${Buffer.from(outputFiles[0].text).toString('base64')}`);
const fixturePublic = { address: '93.184.215.14', family: 4 };

test('first HTML text metadata is bounded and cached under the URL without its fragment', async () => {
  const values = new Map();
  let hops = 0;
  const preview = createLinkPreviewService({
    resolve: async () => [fixturePublic],
    fetchHop: async (url, target) => {
      assert.deepEqual(target, fixturePublic);
      hops++;
      if (url.pathname === '/start') return { location: '/story' };
      return { html: `<head><title>Fallback</title><meta property="og:title" content="News &amp; Notes">
        <meta name="description" content="${'猫'.repeat(400)}"><meta property="og:site_name" content="Example News">
        <meta property="og:image" content="https://images.example.com/story.jpg"></head>` };
    },
    cache: () => ({
      get: async key => values.get(key),
      set: async (key, value, mode, ttl) => {
        assert.match(key, /^neko:link-preview:v1:[a-f0-9]{64}$/);
        assert.equal(mode, 'EX');
        assert.equal(ttl, 3600);
        values.set(key, value);
      },
    }),
  });
  const result = await preview('https://example.com/start#first');
  assert.deepEqual(result, { url: 'https://example.com/story', title: 'News & Notes',
    description: '猫'.repeat(280), site_name: 'Example News' });
  assert.deepEqual(await preview('https://example.com/start#second'), result);
  assert.equal(hops, 2);
});

test('blocked literals and mixed DNS answers never reach the transport', async () => {
  let requests = 0;
  let resolutions = 0;
  const preview = createLinkPreviewService({
    resolve: async host => {
      resolutions++;
      return host === 'public.example.com' ? [fixturePublic] : [fixturePublic, { address: '10.0.0.1', family: 4 }];
    },
    fetchHop: async () => { requests++; return { location: 'https://intranet.example.com/' }; },
  });
  for (const url of ['http://127.0.0.1/', 'http://[::1]/', 'http://169.254.169.254/', 'http://168.63.129.16/', 'https://preview.home.arpa/']) {
    await assert.rejects(preview(url), { statusCode: 400 });
  }
  assert.equal(requests, 0);
  assert.equal(resolutions, 0);
  await assert.rejects(preview('https://public.example.com/'), { statusCode: 400 });
  assert.equal(requests, 1);
});

test('native hop retains the URL host and uses the checked address and byte budget', async t => {
  t.after(() => { delete globalThis.previewTransport; });
  let htmlBytes = 524289;
  globalThis.previewTransport = (url, options, respond) => {
    assert.equal(url.hostname, 'public.example.com');
    assert.equal(options.agent, false);
    assert.equal(options.autoSelectFamily, false);
    assert.equal(options.headers['Accept-Encoding'], 'identity');
    options.lookup(url.hostname, {}, (error, address, family) => {
      assert.equal(error, null);
      assert.deepEqual({ address, family }, fixturePublic);
    });
    const response = Object.assign(Readable.from([Buffer.alloc(htmlBytes), Buffer.from('<title>Plain title</title>')]),
      { statusCode: 200, headers: { 'content-type': 'text/html' } });
    queueMicrotask(() => respond(response));
    return { once() {}, end() {} };
  };
  const preview = createLinkPreviewService({
    resolve: async () => [fixturePublic],
    cache: () => ({ get: async () => { throw new Error(); }, set: async () => {} }),
  });
  assert.equal(await preview('https://public.example.com/'), null);
  htmlBytes = 0;
  assert.equal((await preview('https://public.example.com/')).title, 'Plain title');
});

test('the first card URL comes from text or an actual Markdown link', () => {
  assert.equal(firstPreviewUrl('阅读 https://example.com/news#section。'), 'https://example.com/news');
  assert.equal(firstMarkdownPreviewUrl('![Picture](https://example.com/img)\n\n`https://example.com/code`'), null);
  assert.equal(firstMarkdownPreviewUrl('![Picture](https://example.com/img) [Read](https://example.com/post)'),
    'https://example.com/post');
});
