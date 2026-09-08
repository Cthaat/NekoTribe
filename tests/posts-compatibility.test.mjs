// Real route/middleware/service/model code with an isolated Oracle adapter.
// The adapter models the checked-in fn_can_view_post policy; it is not an Oracle engine.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import { build } from 'esbuild';
import jwt from 'jsonwebtoken';
import { createApp, createRouter, defineEventHandler, toNodeListener } from 'h3';

const root = fileURLToPath(new URL('../', import.meta.url));
const require = createRequire(import.meta.url);
const secret = 'isolated-posts-access-secret';
const stubs = {
  '#imports': `export const useRuntimeConfig = () => ({accessSecret: ${JSON.stringify(secret)}});`,
  '~/server/storage': 'export const normalizeAvatarPublicUrl = value => value; export const normalizeNullableStoragePublicUrl = value => value; export const normalizeStoragePublicUrl = value => value;',
  './notifications': 'export const v2CreateNotification = async () => {};',
  './api-cache': 'export const readApiResponseCache = async () => ({status:"disabled"}); export const writeApiResponseCache = async () => {}; export const invalidateApiResponseCache = async () => {}; export const shouldInvalidateApiResponseCache = () => false;',
  './logging': 'export const getRequestLogContext = () => null; export const logError = () => {}; export const logInfo = () => {}; export const serializeLogError = () => ({});',
  oracledb: 'export default {OUT_FORMAT_OBJECT: 4002};'
};
const compiled = await build({
  stdin: {contents: `
    export {default as auth} from './server/middleware/auth';
    export {default as list} from './server/api/v2/posts/index.get';
    export {default as get} from './server/api/v2/posts/[id].get';
    export {default as create} from './server/api/v2/posts/index.post';
    export {default as remove} from './server/api/v2/posts/[id].delete';
    export {default as update} from './server/api/v2/posts/[id].put';
    export {default as me} from './server/api/v2/users/me/posts.get';
    export {default as bookmarks} from './server/api/v2/users/me/bookmarks.get';
    export {default as likes} from './server/api/v2/users/me/likes.get';
    export {v2ListPosts} from './server/services/v2/posts';
    export {defineV2Handler} from './server/utils/v2';
  `, resolveDir: root, loader: 'ts'},
  bundle: true, write: false, platform: 'node', format: 'esm',
  plugins: [{name: 'isolated-boundaries', setup(builder) {
    builder.onResolve({filter: /.*/}, args => {
      if (Object.hasOwn(stubs, args.path)) return {path: args.path, namespace: 'test-stub'};
      if (args.path.startsWith('~/')) return {path: path.join(root, `${args.path.slice(2)}.ts`)};
      if (args.path.startsWith('node:')) return {path: args.path, external: true};
      if (!args.path.startsWith('.') && !path.isAbsolute(args.path)) return {path: pathToFileURL(require.resolve(args.path)).href, external: true};
    });
    builder.onLoad({filter: /.*/, namespace: 'test-stub'}, args => ({contents: stubs[args.path], loader: 'js'}));
  }}]
});
const routes = await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text + '\n//# sourceURL=isolated-posts-bundle.mjs').toString('base64')}`);
const access = (payload = {}, options = {}) => jwt.sign({userId: 1, userName: 'viewer', sessionId: 'session', jti: 'current', type: 'access', ...payload}, secret, {expiresIn: 600, ...options});

function database({revoked = false, expiredSession = false, failSession = false} = {}) {
  const calls = [];
  const posts = [
    {POST_ID: 1, AUTHOR_ID: 2, VISIBILITY: 'public'},
    {POST_ID: 2, AUTHOR_ID: 2, VISIBILITY: 'private'},
    {POST_ID: 3, AUTHOR_ID: 2, VISIBILITY: 'followers'},
    {POST_ID: 4, AUTHOR_ID: 2, VISIBILITY: 'mentioned', mentioned: 1},
    {POST_ID: 5, AUTHOR_ID: 1, VISIBILITY: 'private'},
    {POST_ID: 6, AUTHOR_ID: 2, VISIBILITY: 'public', deleted: true},
    {POST_ID: 7, AUTHOR_ID: 3, VISIBILITY: 'public'}
  ];
  return {
    calls, close: async () => {},
    async execute(raw, binds = {}) {
      const sql = raw.replace(/\s+/g, ' ').trim(); calls.push({sql, binds});
      if (sql.startsWith('UPDATE n_auth_sessions')) {
        if (failSession) throw new Error('isolated database failure');
        const live = binds.userId === 1 && binds.sessionId === 'session' && binds.accessJti === 'current' && !revoked && (!expiredSession || !sql.includes('access_token_expires_at > CURRENT_TIMESTAMP'));
        return {rowsAffected: live ? 1 : 0};
      }
      if (sql.includes('FROM v_post_feed_item v')) {
        let visible = posts.filter(post => !post.deleted);
        if (sql.includes('fn_can_view_post(:viewer_id, v.post_id) = 1')) visible = visible.filter(post =>
          post.VISIBILITY === 'public' || post.AUTHOR_ID === binds.viewer_id ||
          (binds.viewer_id === 1 && ((post.VISIBILITY === 'followers' && post.AUTHOR_ID === 2) || post.mentioned === 1)));
        if (sql.includes('f.following_id = v.author_id') && sql.includes("f.status = 'active'")) visible = visible.filter(post => binds.viewer_id === 1 && post.AUTHOR_ID === 2);
        if (sql.includes('pm.mentioned_user_id = :viewer_id')) visible = visible.filter(post => post.mentioned === binds.viewer_id);
        if (sql.includes('AND v.author_id = :author_id')) visible = visible.filter(post => post.AUTHOR_ID === binds.author_id);
        if (sql.includes('FROM n_post_bookmarks b')) visible = visible.filter(post => binds.viewer_id === 1 && post.POST_ID === 1);
        if (sql.includes('FROM n_post_likes l')) visible = visible.filter(post => binds.viewer_id === 1 && post.POST_ID === 7);
        if (sql.includes('AND v.post_id = :post_id')) visible = visible.filter(post => post.POST_ID === binds.post_id);
        if (sql.startsWith('SELECT COUNT')) return {rows: [{TOTAL: visible.length}]};
        return {rows: visible.sort((a, b) => b.POST_ID - a.POST_ID).slice(binds.start_row - 1, binds.end_row).map(post => ({...post, CONTENT: `post ${post.POST_ID}`, POST_TYPE: 'original', IS_LIKED: 0, IS_BOOKMARKED: 0}))};
      }
      if (sql.includes('FROM v_user_profile_public u')) return {rows: [{USER_ID: binds.user_id, USERNAME: 'author', RELATION: binds.viewer_id === binds.user_id ? 'self' : 'none'}]};
      if (sql.startsWith('ALTER TABLE n_media_assets')) return {rowsAffected: 0};
      if (sql.includes('FROM user_tab_columns')) return {rows: [{TOTAL: 1}]};
      if (sql.includes('FROM n_post_media') || sql.includes('FROM n_post_tags') || sql.includes('FROM n_post_mentions')) return {rows: []};
      if (sql.startsWith('UPDATE n_post_stats')) return {rowsAffected: 1};
      throw new Error(`Unexpected isolated SQL: ${sql}`);
    }
  };
}

async function fixture(options) {
  const db = database(options);
  const app = createApp();
  app.use(defineEventHandler(event => {event.context.getOracleConnection = async () => db;}));
  app.use(routes.auth);
  const router = createRouter();
  router.get('/api/v2/posts', routes.list);
  router.get('/api/v2/posts/:id', routes.get);
  router.post('/api/v2/posts', routes.create);
  router.put('/api/v2/posts/:id', routes.update);
  router.delete('/api/v2/posts/:id', routes.remove);
  router.get('/api/v2/users/me/posts', routes.me);
  router.get('/api/v2/users/me/bookmarks', routes.bookmarks);
  router.get('/api/v2/users/me/likes', routes.likes);
  router.get('/api/v2/groups/:id/posts', defineEventHandler(() => {throw new Error('Anonymous group route was reached');}));
  // Exercise the service guards independently of route-level auth for these modes.
  for (const mode of ['me', 'bookmarks', 'likes']) router.get(`/isolated/${mode}`, routes.defineV2Handler((event, connection) => routes.v2ListPosts(event, connection, {mode})));
  app.use(router);
  const server = createServer(toNodeListener(app));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  return {db, close: () => new Promise(resolve => server.close(resolve)), request: (url, headers = {}, method = 'GET') => fetch(base + url, {method, headers})};
}

test('anonymous public list uses null viewer, correct visibility/count/pagination and neutral viewer state', async () => {
  const f = await fixture();
  try {
    const response = await f.request('/api/v2/posts?page=1&page_size=1'); assert.equal(response.status, 200);
    const body = await response.json(); assert.deepEqual(body.data.map(post => post.post_id), [7]);
    assert.deepEqual(body.meta, {page: 1, page_size: 1, total: 2, has_next: true});
    assert.deepEqual(body.data[0].viewer_state, {is_liked: false, is_bookmarked: false, can_delete: false});
    const page2 = await (await f.request('/api/v2/posts?page=2&page_size=1')).json(); assert.deepEqual(page2.data.map(post => post.post_id), [1]); assert.equal(page2.meta.has_next, false);
    assert.ok(f.db.calls.filter(call => call.sql.includes('FROM v_post_feed_item')).every(call => call.binds.viewer_id === null && call.sql.includes('fn_can_view_post')));
  } finally {await f.close();}
});

test('anonymous detail excludes private/followers/mentioned/deleted/group posts without incrementing their views', async () => {
  const f = await fixture();
  try {
    for (const id of [2, 3, 4, 5, 6, 99]) assert.equal((await f.request(`/api/v2/posts/${id}`)).status, 404);
    assert.equal(f.db.calls.filter(call => call.sql.startsWith('UPDATE n_post_stats')).length, 0);
    assert.equal((await f.request('/api/v2/posts/1')).status, 200);
    assert.equal(f.db.calls.filter(call => call.sql.startsWith('UPDATE n_post_stats')).length, 1);
  } finally {await f.close();}
});

test('personal modes, following/mentions and non-GET methods require authentication', async () => {
  const f = await fixture();
  try {
    for (const url of ['/api/v2/users/me/posts', '/api/v2/users/me/bookmarks', '/api/v2/users/me/likes', '/isolated/me', '/isolated/bookmarks', '/isolated/likes', '/api/v2/posts?timeline=following', '/api/v2/posts?timeline=mentions', '/api/v2/groups/1/posts']) assert.equal((await f.request(url)).status, 401, url);
    for (const [url, method] of [['/api/v2/posts', 'POST'], ['/api/v2/posts/1', 'PUT'], ['/api/v2/posts/1', 'DELETE'], ['/api/v2/posts/1', 'HEAD']]) assert.equal((await f.request(url, {}, method)).status, 401);
    assert.equal(f.db.calls.length, 0);
  } finally {await f.close();}
});

test('valid Cookie/Bearer access enables following, mentions and personal filters with matching counts', async () => {
  const f = await fixture();
  try {
    for (const headers of [{authorization: `Bearer ${access()}`}, {cookie: `access_token=${access()}`}]) {
      for (const [url, ids] of [['/api/v2/posts?timeline=following', [4, 3, 1]], ['/api/v2/posts?timeline=mentions', [4]], ['/api/v2/users/me/posts', [5]], ['/api/v2/users/me/bookmarks', [1]], ['/api/v2/users/me/likes', [7]]]) {
        const response = await f.request(url, headers); assert.equal(response.status, 200, url);
        const body = await response.json(); assert.deepEqual(body.data.map(post => post.post_id), ids); assert.equal(body.meta.total, ids.length);
      }
    }
    const queries = f.db.calls.filter(call => call.sql.includes('f.following_id = v.author_id'));
    assert.equal(queries.length, 4); assert.ok(queries.every(call => call.sql.includes("f.status = 'active'") && call.binds.viewer_id === 1));
  } finally {await f.close();}
});

test('supplied malformed, expired, wrong-type or incomplete tokens are never treated as anonymous or trusted', async () => {
  const f = await fixture();
  try {
    for (const token of ['invalid', access({}, {expiresIn: -1}), access({type: 'refresh'}), access({sessionId: null}), access({jti: null}), access({userId: 1.5})]) {
      for (const url of ['/api/v2/posts', '/api/v2/posts?timeline=following']) assert.equal((await f.request(url, {authorization: `Bearer ${token}`})).status, 401);
    }
    assert.equal((await f.request('/api/v2/posts', {cookie: 'access_token=invalid', authorization: `Bearer ${access()}`})).status, 401);
    assert.equal(f.db.calls.filter(call => call.sql.includes('FROM v_post_feed_item')).length, 0);
  } finally {await f.close();}
});

for (const options of [{revoked: true}, {expiredSession: true}, {failSession: true}]) {
  test(`invalid stored session does not assign privileged viewer: ${JSON.stringify(options)}`, async () => {
    const f = await fixture(options);
    try {
      for (const url of ['/api/v2/posts', '/api/v2/posts?timeline=following', '/api/v2/users/me/posts']) assert.equal((await f.request(url, {authorization: `Bearer ${access()}`})).status, 401);
      assert.equal(f.db.calls.filter(call => call.sql.includes('FROM v_post_feed_item')).length, 0);
    } finally {await f.close();}
  });
}
