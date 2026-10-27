// Real route identity, payload parser and update service; no sockets or application startup.
// Only Oracle storage, final post reload, cache/logging and notifications are isolated.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createRequire } from 'node:module';
import { ServerResponse } from 'node:http';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import { build } from 'esbuild';
import { createEvent } from 'h3';

const root = fileURLToPath(new URL('../', import.meta.url));
const require = createRequire(import.meta.url);
const stubs = {
  '~/server/models/v2': `
    export const v2RequirePostById = async connection => connection.snapshot();
    const unexpected = () => { throw new Error('Unexpected model boundary'); };
    export const v2CommentCount = unexpected, v2MapComment = unexpected,
      v2MapPost = unexpected, v2MapPublicUser = unexpected,
      v2PostCountSql = unexpected, v2PostSelectSql = unexpected, v2SortOrder = unexpected;
  `,
  './notifications': 'export const v2CreateNotification = async () => {};',
  './api-cache': 'export const readApiResponseCache = async () => ({status:"disabled"}); export const writeApiResponseCache = async () => {}; export const invalidateApiResponseCache = async () => {}; export const shouldInvalidateApiResponseCache = () => false;',
  './logging': 'export const getRequestLogContext = () => null; export const logError = () => {}; export const logInfo = () => {}; export const serializeLogError = () => ({});',
  './client': 'export const v2RequestData = async (path, options) => ({path, options}); export const v2Request = async () => {}; export const toV2PagedResult = value => value;',
  oracledb: 'export default {OUT_FORMAT_OBJECT: 4002};'
};
const compiled = await build({
  stdin: { contents: `
    export {default as patch} from './server/api/v2/posts/[id].patch';
    export {default as put} from './server/api/v2/posts/[id].put';
    export {v2UpdatePost as updateClient} from './app/api/v2/posts';
  `, resolveDir: root, loader: 'ts' },
  bundle: true, write: false, platform: 'node', format: 'esm',
  plugins: [{ name: 'offline-post-update-boundaries', setup(builder) {
    builder.onResolve({ filter: /.*/ }, args => {
      if (Object.hasOwn(stubs, args.path)) return { path: args.path, namespace: 'test-stub' };
      if (args.path.startsWith('~/')) return { path: path.join(root, `${args.path.slice(2)}.ts`) };
      if (args.path.startsWith('node:')) return { path: args.path, external: true };
      if (!args.path.startsWith('.') && !path.isAbsolute(args.path)) return { path: pathToFileURL(require.resolve(args.path)).href, external: true };
    });
    builder.onLoad({ filter: /.*/, namespace: 'test-stub' }, args => ({ contents: stubs[args.path], loader: 'js' }));
  } }]
});
const routes = await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);

function database(overrides = {}) {
  const state = { post_id: 7, author_id: 1, content: 'original content', visibility: 'followers', language: 'zh', location: 'original location', media_ids: [11], tag_names: ['original-tag'], mention_user_ids: [2], ...overrides };
  const writes = [];
  return {
    state, writes,
    close: async () => {},
    snapshot: () => structuredClone(state),
    async execute(raw, binds = {}) {
      const sql = raw.replace(/\s+/g, ' ').trim();
      if (sql.startsWith('SELECT') && sql.includes('FROM n_posts')) return { rows: [{ AUTHOR_ID: state.author_id, IS_DELETED: 0, POST_TYPE: 'original', CONTENT: state.content }] };
      if (sql.startsWith('SELECT COUNT') && sql.includes('FROM n_post_media')) return { rows: [{ TOTAL: state.media_ids.length }] };
      if (sql.startsWith('UPDATE n_posts')) {
        writes.push({ sql, binds });
        for (const field of ['content', 'visibility', 'language', 'location']) {
          if (sql.includes(`${field} = :${field}`)) state[field] = binds[field];
        }
        return { rowsAffected: 1 };
      }
      for (const [table, field] of [['n_post_media', 'media_ids'], ['n_post_tags', 'tag_names'], ['n_post_mentions', 'mention_user_ids']]) {
        if (sql.startsWith(`DELETE FROM ${table}`)) {
          writes.push({ sql, binds });
          state[field] = [];
          return { rowsAffected: 1 };
        }
      }
      throw new Error(`Unexpected isolated update SQL: ${sql}`);
    }
  };
}

async function invoke(method, payload, db, auth = { userId: 1 }) {
  const request = { method, url: '/api/v2/posts/7', headers: { 'content-type': 'application/json' }, body: payload };
  const response = new ServerResponse(request);
  const event = createEvent(request, response);
  event.context.params = { id: '7' };
  event.context.auth = auth;
  event.context.getOracleConnection = async () => db;
  try { return await routes[method.toLowerCase()](event); }
  finally { response.destroy(); }
}

test('canonical PATCH and legacy PUT export the identical live handler', () => {
  assert.equal(routes.patch, routes.put);
});

for (const method of ['PATCH', 'PUT']) {
  test(`${method} updates supplied content and preserves every omitted scalar/relation`, async () => {
    const db = database();
    const before = db.snapshot();
    const response = await invoke(method, { content: 'edited content' }, db);
    assert.equal(response.code, 200);
    assert.equal(response.message, 'post updated');
    assert.deepEqual(response.data, { ...before, content: 'edited content' });
    assert.equal(db.writes.length, 1);
    assert.deepEqual(db.writes[0].binds, { post_id: 7, content: 'edited content' });
  });

  test(`${method} empty JSON object is a read-only no-op for an existing valid post`, async () => {
    const db = database();
    const before = db.snapshot();
    assert.deepEqual((await invoke(method, {}, db)).data, before);
    assert.equal(db.writes.length, 0);
  });

  test(`${method} explicit empty tag_names clears tags while omitted media and mentions survive`, async () => {
    const db = database();
    const before = db.snapshot();
    assert.deepEqual((await invoke(method, { tag_names: [] }, db)).data, { ...before, tag_names: [] });
    assert.equal(db.writes.filter(call => call.sql.startsWith('DELETE FROM n_post_tags')).length, 1);
    assert.ok(db.writes.every(call => !call.sql.startsWith('DELETE FROM n_post_media') && !call.sql.startsWith('DELETE FROM n_post_mentions')));
  });

  test(`${method} preserves authentication, ownership and content validation before writes`, async () => {
    const unauthenticated = database();
    await assert.rejects(invoke(method, {}, unauthenticated, null), error => error.statusCode === 401);
    assert.equal(unauthenticated.writes.length, 0);
    const otherOwner = database({ author_id: 2 });
    await assert.rejects(invoke(method, { content: 'unauthorized edit' }, otherOwner), error => error.statusCode === 422);
    assert.equal(otherOwner.writes.length, 0);
    const noMedia = database({ media_ids: [] });
    await assert.rejects(invoke(method, { content: '' }, noMedia), error => error.statusCode === 400);
    assert.equal(noMedia.writes.length, 0);
  });
}

test('Nuxt update client sends PATCH with the unchanged partial payload', async () => {
  const payload = { location: null, tag_names: [] };
  const request = await routes.updateClient(7, payload);
  assert.equal(request.path, '/api/v2/posts/7');
  assert.equal(request.options.method, 'PATCH');
  assert.equal(request.options.body, payload);
});
