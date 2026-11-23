import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { build } from 'esbuild';

const compiled = await build({
  entryPoints:[fileURLToPath(new URL('../app/utils/post-edit.ts',import.meta.url))],
  bundle:true,write:false,platform:'node',format:'esm',
});
const {postEditMediaIds,postEditOwned,postEditPatch,postEditTarget} =
  await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);

test('edit links accept only the canonical post ID and exact current owner', () => {
  for (const value of [undefined, ['42'], ' 42', '042', '1e2', '0', '-1', '9007199254740992']) {
    assert.equal(postEditTarget(value), null);
  }
  const id = postEditTarget('42');
  assert.equal(id, 42);
  const post = { id, author: { id: 9 } };
  assert.equal(postEditOwned(post, id, 9), true);
  assert.equal(postEditOwned(post, id, 10), false);
  assert.equal(postEditOwned(post, 43, 9), false);
});

test('post edits preserve untouched fields and send deliberate empty values', () => {
  const initial = { content: 'Body #Old', visibility: 'mentioned', language: 'en', location: 'Old Place', tags: 'old, cats' };
  assert.deepEqual(postEditPatch(initial, { ...initial }), {});
  assert.deepEqual(postEditPatch(initial, { ...initial, location: '' }), { location: '' });
  assert.deepEqual(postEditPatch(initial, { ...initial, content: 'New #Old' }), { content: 'New #Old' });
  assert.deepEqual(postEditPatch(initial, { ...initial, content: 'New #Nuxt', tags: 'cats, Flutter' }), {
    content: 'New #Nuxt', tagNames: ['nuxt', 'cats', 'flutter']
  });
  assert.deepEqual(postEditPatch({ ...initial, content: 'Body' }, { ...initial, content: 'Body', tags: '' }), { tagNames: [] });
});

test('attachment edits omit untouched relations and preserve retained order', () => {
  const media = [{ id: 3 }, { id: 2, privateFileName: '' }, { id: 1 }];
  assert.equal(postEditMediaIds(media, new Set(), false), undefined);
  assert.deepEqual(postEditMediaIds(media, new Set([1]), false), [3, 2]);
  assert.deepEqual(postEditMediaIds(media, new Set([3]), true), [1]);
  assert.deepEqual(postEditMediaIds(media, new Set([1, 3]), true), []);
});

test('Markdown edits keep raw body separate from the excerpt and explicitly remove long format', () => {
  const initial={content:'Plain summary',visibility:'public',language:'en',location:'',tags:''};
  const raw='## Heading\n\n'+'x'.repeat(600);
  const rich={...initial,content:raw,markdown:true};
  const changed=postEditPatch(initial,rich);
  assert.equal(changed.content.length,280);
  assert.equal(changed.markdown,raw);
  assert.deepEqual(postEditPatch(rich,{...rich,location:'Shanghai'}),{location:'Shanghai'});
  assert.deepEqual(postEditPatch(rich,initial),{content:'Plain summary',markdown:null});
});
