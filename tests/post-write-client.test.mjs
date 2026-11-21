import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';

const compiled = await build({
    stdin: {
      contents: `export { v2GetPost, v2CreatePost, v2CreateRetweet, v2DeletePost, v2UpdatePost, v2LikePost, v2UnlikePost, v2BookmarkPost, v2UnbookmarkPost } from './app/api/v2/posts.ts';
        export { setReceipt } from 'fixture:client';`,
      resolveDir: fileURLToPath(new URL('../', import.meta.url)),
    },
    bundle: true,
    write: false,
    platform: 'node',
    format: 'esm',
    plugins: [{ name: 'retweet-reply', setup(builder) {
      builder.onResolve({ filter: /^\.\/client$|^fixture:client$/ }, () => ({ path: 'client', namespace: 'fixture' }));
      builder.onLoad({ filter: /.*/, namespace: 'fixture' }, () => ({ contents: `
        export const toV2PagedResult = response => response;
        export function v2Request(path, options) {
          if (path === '/api/v2/posts/42' && ['DELETE', 'PATCH'].includes(options.method)) return receipt;
          throw Error('Unexpected call');
        }
        let receipt;
        export function setReceipt(value) { receipt = value; }
        export function v2RequestData(path, options) {
          if (path === '/api/v2/posts/42' && options.method === 'GET') return receipt;
          if (path === '/api/v2/posts' && options.method === 'POST') return receipt;
          if (path === '/api/v2/posts/42/likes' || path === '/api/v2/posts/42/bookmarks') return {...receipt, method: options.method};
          if (path !== '/api/v2/posts/42/retweets' || options.method !== 'POST') throw Error('Wrong request');
          return JSON.parse(options.body.content);
        }
      ` }));
    } }],
});
const { v2GetPost, v2CreatePost, v2CreateRetweet, v2DeletePost, v2UpdatePost, v2LikePost, v2UnlikePost, v2BookmarkPost, v2UnbookmarkPost, setReceipt } = await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);

test('post detail only accepts the requested post', async () => {
  setReceipt({ post_id: 42 });
  assert.equal((await v2GetPost(42)).post_id, 42);
  for (const receipt of [null, { post_id: 7 }, { post_id: '42' }]) {
    setReceipt(receipt);
    await assert.rejects(v2GetPost(42), /Invalid post detail response/);
  }
});

test('edit client confirms the saved post identity and owner permissions', async () => {
  const data = { post_id: 42, author: { user_id: 9 }, viewer_state: { can_delete: true } };
  const valid = { code: 200, message: 'post updated', data, meta: null };
  setReceipt(valid);
  assert.deepEqual(await v2UpdatePost(42, { content: 'new' }), data);
  for (const invalid of [
    { ...valid, message: 'success' },
    { ...valid, meta: undefined },
    { ...valid, data: null },
    { ...valid, data: { ...data, post_id: '42' } },
    { ...valid, data: { ...data, author: { user_id: 0 } } },
    { ...valid, data: { ...data, viewer_state: { can_delete: false } } },
  ]) {
    setReceipt(invalid);
    await assert.rejects(v2UpdatePost(42, {}), { name: 'UnconfirmedPostUpdateError' });
  }
});

test('delete client requires the post deletion envelope', async () => {
  const valid = { code: 200, message: 'post deleted', data: null, meta: null };
  setReceipt(valid);
  await v2DeletePost(42);
  for (const invalid of [null, {}, { ...valid, code: 40401 }, { ...valid, message: 'success' }, { ...valid, data: {} }, { ...valid, meta: undefined }]) {
    setReceipt(invalid);
    await assert.rejects(v2DeletePost(42), /Invalid post delete response/);
  }
});

test('post creation confirms the new ID and requested reference', async () => {
  for (const reference of [{}, { reply_to_post_id: 42 }, { quoted_post_id: 42 }]) {
    const valid = { post_id: 53, ...reference };
    setReceipt(valid);
    const publish = () => v2CreatePost({ content: 'draft', ...reference });
    assert.deepEqual(await publish(), valid);
    for (const invalid of [null, { ...valid, post_id: 0 }, { ...valid, post_id: '53' }, { ...valid, repost_of_post_id: 53 }]) {
      setReceipt(invalid);
      await assert.rejects(publish(), { name: 'UnconfirmedPostError' });
    }
  }
  for (const invalid of [{ post_id: 53 }, { post_id: 53, quoted_post_id: 43 }, { post_id: 42, quoted_post_id: 42 }]) {
    setReceipt(invalid);
    await assert.rejects(v2CreatePost({ quoted_post_id: 42 }), { name: 'UnconfirmedPostError' });
  }
});

test('retweet client confirms the new post references the requested original', async () => {
  const create = response => v2CreateRetweet(42, { content: JSON.stringify(response), visibility: 'public' });
  const valid = { post_id: 53, repost_of_post_id: 42 };
  assert.deepEqual(await create(valid), valid);
  for (const body of [null, { ...valid, post_id: 42 }, { ...valid, repost_of_post_id: 43 }, { ...valid, post_id: 0 }]) {
    await assert.rejects(create(body), { name: 'UnconfirmedRetweetError' });
  }
});

test('post like and bookmark check identity and use the server response', async () => {
  setReceipt({ post_id: 42, is_liked: true, likes_count: 42 });
  assert.equal((await v2LikePost(42)).likes_count, 42);
  assert.equal((await v2UnlikePost(42)).method, 'DELETE');
  setReceipt({ post_id: 41, is_liked: true, likes_count: 42 });
  await assert.rejects(v2LikePost(42), /Invalid post like response/);
  setReceipt({ post_id: 42, is_liked: true, likes_count: -1 });
  await assert.rejects(v2LikePost(42), /Invalid post like response/);
  setReceipt({ post_id: 42, is_bookmarked: true });
  assert.equal((await v2BookmarkPost(42)).is_bookmarked, true);
  assert.equal((await v2UnbookmarkPost(42)).method, 'DELETE');
  setReceipt({ post_id: 41, is_bookmarked: true });
  await assert.rejects(v2BookmarkPost(42), /Invalid post bookmark response/);
});
