import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { test } from 'node:test';
import { compileScript, parse } from '@vue/compiler-sfc';
import { transformSync } from 'esbuild';
import { effectScope, nextTick, reactive } from 'vue';
import { beginRepost } from '../app/utils/optimistic-repost.ts';
import { groupBookmarkKey, toggleGroupBookmark } from '../app/utils/group-bookmark.ts';

const read = path => readFileSync(new URL('../' + path, import.meta.url), 'utf8');
test('odometer renders the outgoing and incoming values in the same update, including reversal', async () => {
  const { descriptor } = parse(read('app/components/motion/AnimatedNumber.vue'));
  const compiled = compileScript(descriptor, { id: 'odometer', inlineTemplate: true });
  const module = { exports: {} };
  const { code } = transformSync(compiled.content, { loader: 'ts', format: 'cjs' });
  new Function('require', 'module', code)(createRequire(import.meta.url), module);
  const scope = effectScope();
  const props = reactive({ value: 9, hideZero: false });
  const render = scope.run(() => module.exports.default.setup(props));
  try {
    for (const [from, to] of [[9, 10], [10, 11], [11, 8], [8, 0]]) {
      props.value = to;
      await nextTick();
      const slots = render({}, []).children[2];
      assert.equal(slots.props.style['--roll'], to > from ? '100%' : '-100%');
      assert.deepEqual(slots.children.map(slot => slot.children), [String(from), String(to)]);
    }
  } finally { scope.stop(); }
});

test('repost rollback preserves concurrent likes and a newer server count', () => {
  let post = { id: 3, counts: { retweets: 5, likes: 2 } };
  const patch = (id, update) => { assert.equal(id, post.id); post = update(post); };
  const undo = beginRepost(3, patch);
  assert.equal(post.counts.retweets, 6);
  post.counts.likes++;
  undo();
  assert.deepEqual(post.counts, { retweets: 5, likes: 3 });
  const stale = beginRepost(3, patch);
  post.counts.retweets = 9;
  stale();
  assert.equal(post.counts.retweets, 9);
});

test('local group bookmarks isolate all three ids and roll back failed persistence', () => {
  const keys = [[1,2,3],[2,2,3],[1,3,3],[1,2,4]].map(ids => groupBookmarkKey(...ids));
  assert.equal(new Set(keys).size, 4);
  const marks = {}, entries = new Map();
  const storage = () => ({ setItem: (k,v) => entries.set(k,v), removeItem: k => entries.delete(k) });
  toggleGroupBookmark(marks, keys[0], storage);
  assert.equal(entries.get(keys[0]), '1');
  assert.throws(() => toggleGroupBookmark(marks, keys[0], () => { throw Error('unavailable'); }));
  assert.equal(marks[keys[0]], true);
  toggleGroupBookmark(marks, keys[0], storage);
  assert.equal(entries.size, 0);
});

test('content cards and reduced effects retain an opaque, static reading surface', () => {
  for (const name of ['TweetCard','GroupPostCard','GroupCard']) {
    assert.doesNotMatch(read('app/components/' + name + '.vue'), /backdrop-blur|liquid-glass/);
  }
  const css = read('app/assets/css/content-motion.css');
  assert.match(css, /prefers-reduced-motion: reduce[^}]+\.odometer-out\s*\{ display: none/s);
  assert.match(css, /prefers-reduced-transparency: reduce[^}]+\.w3-shimmer\s*\{ background: var\(--secondary\)/s);
  assert.match(css, /prefers-reduced-motion: no-preference\) and \(prefers-reduced-transparency: no-preference\)[\s\S]+@keyframes w3-sweep/);
});

test('media fade covers already decoded images and later sources exactly once', () => {
  const calls = [];
  class Image {
    complete = true;
    currentSrc = '/first.png';
    naturalWidth = 100;
    animate(frames, timing) { calls.push({ frames, timing }); }
  }
  const image = new Image();
  const preference = { matches: false };
  let loaded;
  const document = {
    images: [image],
    addEventListener(name, listener, capture) {
      assert.equal(name, 'load');
      assert.equal(capture, true);
      loaded = listener;
    }
  };
  const { code } = transformSync(read('app/plugins/media-fade.client.ts'), {
    loader: 'ts', format: 'cjs', define: { 'import.meta.hot': 'false' }
  });
  new Function('module', 'defineNuxtPlugin', 'HTMLImageElement', 'matchMedia', 'document', code)(
    { exports: {} }, setup => setup(), Image, () => preference, document
  );
  loaded({ target: image });
  assert.deepEqual(calls, [{ frames: [{ opacity: 0 }, { opacity: 1 }], timing: { duration: 180, easing: 'ease-out' } }]);
  image.currentSrc = '/second.png';
  preference.matches = true;
  loaded({ target: image });
  assert.equal(calls.length, 1);
  preference.matches = false;
  loaded({ target: image });
  assert.equal(calls.length, 2);
});
