import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { ref } from 'vue';
import { resistedIndex, snapIndex, useLiquidScrub } from '../app/composables/useLiquidScrub.ts';
import { tabDirection } from '../app/composables/useTabTransitionDirection.ts';
import { useMediaGallery } from '../app/composables/useMediaGallery.ts';

test('scrub damps both edges and predicts a reachable enabled target on release', () => {
  assert.ok(resistedIndex(-1, 3, false) < 0 && resistedIndex(-1, 3, false) > -0.24);
  assert.ok(resistedIndex(8, 3, false) > 3 && resistedIndex(8, 3, false) <= 3.24);
  assert.equal(resistedIndex(8, 3, true), 3);
  assert.equal(snapIndex(1.3, 0.008, [0, 1, 2]), 2);
  assert.equal(snapIndex(1.3, -0.01, [0, 2]), 0);
});

test('pointer scrub commits once, releases stale velocity and cancels without changing selection', t => {
  const hadMedia = Object.hasOwn(globalThis, 'matchMedia');
  if (!hadMedia) Object.defineProperty(globalThis, 'matchMedia', { configurable: true, value: () => ({ matches: false }) });
  t.after(() => { if (!hadMedia) delete globalThis.matchMedia; });
  const selected = [];
  const { events, pressed, pillStyle } = useLiquidScrub(ref(0), i => selected.push(i));
  const item = { isConnected: true, matches: () => false, setPointerCapture() {},
    getBoundingClientRect: () => ({ left: 10, width: 100 }) };
  const event = { pointerId: 1, isPrimary: true, button: 0, clientY: 0, clientX: 60, timeStamp: 10,
    currentTarget: { querySelectorAll: () => [item, item, item] }, target: { closest: () => item } };
  for (const end of ['pointercancel', 'lostpointercapture', 'pointerup']) {
    events.pointerdown(event);
    events.pointermove({ ...event, clientX: 195, timeStamp: 26 });
    assert.equal(pressed.value, true);
    assert.ok(Math.abs(pillStyle.value['--stretch-x'] * pillStyle.value['--stretch-y'] - 1) < 1e-9);
    events[end]({ ...event, clientX: 195, timeStamp: 180 });
    assert.equal(pressed.value, false);
  }
  assert.deepEqual(selected, [1]);
  let blocked = false;
  events.clickCapture({ detail: 1, preventDefault() { blocked = true; }, stopPropagation() {} });
  assert.equal(blocked, true);
  events.clickCapture({ detail: 0, preventDefault: assert.fail });
});

test('localized primary routes reverse immediately across chat layout and ignore detail routes', () => {
  const order = ['/en', '/en/groups/discover', '/en/user/7/notifications', '/en/chat', '/en/user/7/profile'];
  for (let i = 1; i < order.length; i++) {
    assert.equal(tabDirection(order[i - 1], order[i]), 'forward');
    assert.equal(tabDirection(order[i], order[i - 1]), 'back');
  }
  assert.equal(tabDirection('/zh/chat', '/tweet/3'), 'fade');
  assert.equal(tabDirection('/chat', '/en/chat'), 'fade');
});

test('gallery closes to the currently displayed thumbnail at its live position', () => {
  const gallery = useMediaGallery();
  let left = 2;
  const thumbs = ['a', 'b'].map(url => ({ dataset: { mediaUrl: url }, isConnected: true,
    getBoundingClientRect: () => ({ left: url === 'a' ? 0 : left }) }));
  gallery.show(0, { currentTarget: { parentElement: { querySelectorAll: () => thumbs } } });
  left = 90;
  assert.equal(gallery.originRect('b').left, 90);
  thumbs[1].isConnected = false;
  assert.equal(gallery.originRect('b'), null);
});

test('reduced optics and motion have independent fallbacks and content surfaces stay matte', () => {
  const read = path => readFileSync(new URL('../' + path, import.meta.url), 'utf8');
  const css = read('app/assets/css/tailwind.css');
  assert.match(css, /@media \(prefers-reduced-transparency: reduce\)\s*\{\s*\.liquid-glass-active-pill[^}]*background-image: none/);
  assert.match(css, /@media \(prefers-reduced-motion: reduce\)\s*\{\s*\[data-pressed='true'\] \.scrub-pill \{ transform: translateX\(var\(--scrub-x\)\); \}/);
  assert.doesNotMatch(css.match(/\.bento-card\s*\{([^}]*)\}/)[1], /backdrop|--glass/);
  for (const name of ['TweetCard', 'GroupCard', 'GroupPostCard']) {
    const template = read('app/components/' + name + '.vue').split('<template>')[1];
    assert.doesNotMatch(template, /backdrop-blur|liquid-glass-(?:dock|island|popover)/);
  }
});
