import assert from 'node:assert/strict';
import test from 'node:test';
import { readAppShortcut } from '../app/utils/app-shortcuts.ts';

function key(key, modifiers = {}) {
  return {
    key,
    altKey: false,
    ctrlKey: false,
    metaKey: false,
    shiftKey: false,
    isComposing: false,
    defaultPrevented: false,
    repeat: false,
    ...modifiers
  };
}

test('opens the palette with the platform modifier and K', () => {
  assert.equal(readAppShortcut(key('k', { ctrlKey: true })), 'palette');
  assert.equal(readAppShortcut(key('K', { metaKey: true }), { editable: true }), 'palette');
  assert.equal(readAppShortcut(key('k', { ctrlKey: true, shiftKey: true })), null);
});

test('maps timeline commands and help only outside editors and dialogs', () => {
  const timeline = { j: 'next', k: 'previous', l: 'like', b: 'bookmark', r: 'reply', n: 'compose' };
  for (const [letter, action] of Object.entries(timeline)) {
    assert.equal(readAppShortcut(key(letter)), action);
    assert.equal(readAppShortcut(key(letter), { editable: true }), null);
    assert.equal(readAppShortcut(key(letter), { modalOpen: true }), null);
  }
  assert.equal(readAppShortcut(key('?', { shiftKey: true })), 'help');
  assert.equal(readAppShortcut(key('J', { shiftKey: true })), null);
});

test('ignores composition, already handled events and repeat mutations', () => {
  assert.equal(readAppShortcut(key('k', { ctrlKey: true, isComposing: true })), null);
  assert.equal(readAppShortcut(key('b', { defaultPrevented: true })), null);
  assert.equal(readAppShortcut(key('l', { repeat: true })), null);
  assert.equal(readAppShortcut(key('j', { altKey: true })), null);
});
