import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { ref } from 'vue';
import { useSheetDrag } from '../app/composables/useSheetDrag.ts';

const read = path => readFileSync(new URL('../' + path, import.meta.url), 'utf8');
const css = read('app/assets/css/glass-overlays.css');

test('sheet only dismisses on a primary captured downward drag of at least 64px', () => {
  const captures = [];
  let closes = 0;
  const drag = useSheetDrag(ref({setPointerCapture: id => captures.push(id)}), () => closes++);
  const pointer = (y, id = 1) => ({pointerId: id, clientY: y, button: 0, isPrimary: true});
  drag.start({...pointer(10), isPrimary: false});
  drag.finish(pointer(160));
  drag.start(pointer(10));
  drag.move(pointer(110, 2));
  assert.equal(drag.offset.value, 0);
  drag.move(pointer(95));
  assert.equal(drag.offset.value, 85);
  drag.cancel(pointer(95));
  drag.finish(pointer(95));
  drag.start(pointer(10));
  drag.move(pointer(0));
  assert.equal(drag.offset.value, 0);
  drag.finish(pointer(73));
  assert.equal(closes, 0);
  drag.start(pointer(10));
  drag.finish(pointer(74));
  assert.deepEqual(captures, [1, 1, 1]);
  assert.equal(closes, 1);
  assert.equal(drag.offset.value, 0);
});

test('reduced motion turns off floating entrances and reduced transparency removes optics', () => {
  assert.match(css, /@media \(prefers-reduced-motion: reduce\)\s*\{[^}]*\.glass-float[^}]*animation: none/);
  assert.match(css, /@media \(prefers-reduced-transparency: reduce\)[\s\S]*?\.glass-toast[^}]*background-image: none/);
  assert.match(css, /@media \(prefers-reduced-transparency: reduce\)[\s\S]*?backdrop-filter: none/);
  for (const path of ['dialog/DialogContent', 'popover/PopoverContent', 'dropdown-menu/DropdownMenuContent']) {
    assert.match(read('app/components/ui/' + path + '.vue'), /glass-float/);
  }
});

test('content cards and their media badges keep all glass treatments off the reading surface', () => {
  for (const name of ['TweetCard', 'GroupPostCard', 'GroupCard']) {
    assert.doesNotMatch(read('app/components/' + name + '.vue'), /liquid-glass-|backdrop-(?:blur|filter)|glass-float/);
  }
  const bento = read('app/assets/css/tailwind.css').match(/\.bento-card\s*\{([^}]+)\}/);
  assert.ok(bento);
  assert.doesNotMatch(bento[1], /backdrop|glass/);
  assert.doesNotMatch(css, /\.bento-card/);
});
