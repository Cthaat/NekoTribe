import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { Readable } from 'node:stream';
import { DatabaseSync } from 'node:sqlite';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';
import { createApp, createRouter, eventHandler, toNodeListener } from 'h3';

const root = fileURLToPath(new URL('../', import.meta.url));
const { query } = JSON.parse(readFileSync(new URL('../specifications/requirements/media-private-read.json', import.meta.url)));
const binding = JSON.parse(readFileSync(new URL('../specifications/requirements/media-private-bind.json', import.meta.url)));
const { sql: directSql } = JSON.parse(readFileSync(new URL('../specifications/requirements/direct-message-extras.json', import.meta.url)));

test('private bindings are limited to one compatible content association', () => {
  const db = new DatabaseSync(':memory:');
  try {
    db.function('CHR', (code) => String.fromCodePoint(code));
    db.exec(`
      CREATE TABLE n_media_assets(media_id, storage_key, access_scope, status);
      CREATE TABLE n_chat_message_media(media_id, message_id);
      CREATE TABLE n_post_media(media_id, post_id);
      INSERT INTO n_media_assets VALUES (1,'private/chat/a.txt','chat','ready'),
        (2,'private/post/b.txt','post','ready'), (3,'private/post/c.txt','post','processing'),
        (4,'posts/files/d.txt','public','ready');
    `);
    const chat = db.prepare(binding.chat);
    const post = db.prepare(binding.post);
    const retained = db.prepare(binding.retained.replace('AND ROWNUM = 1', 'LIMIT 1'));
    assert.equal(chat.get({media_id:1}).permitted, 1);
    assert.equal(chat.get({media_id:2}), undefined);
    assert.equal(post.get({media_id:2,post_id:10}).permitted, 1);
    assert.equal(post.get({media_id:3,post_id:10}), undefined);

    db.exec('INSERT INTO n_chat_message_media VALUES (1,100); INSERT INTO n_post_media VALUES (2,10),(4,11)');
    assert.equal(chat.get({media_id:1}), undefined);
    assert.equal(post.get({media_id:2,post_id:10}).permitted, 1);
    assert.equal(post.get({media_id:2,post_id:11}), undefined);
    assert.equal(retained.get({post_id:10}).found, 1);
    assert.equal(retained.get({post_id:11}), undefined);
  } finally {
    db.close();
  }
});

test('private access requires owner preview or a currently visible, matching association', () => {
  const db = new DatabaseSync(':memory:');
  try {
    db.function('fn_can_view_post', (viewer, post) => viewer === 2 && post === 10 ? 1 : 0);
    db.exec(`
      CREATE TABLE n_media_assets(media_id, storage_key, access_scope, owner_user_id, status);
      CREATE TABLE n_users(user_id, is_active, status);
      CREATE TABLE n_user_blocks(user_id, target_user_id);
      CREATE TABLE n_chat_message_media(media_id, message_id);
      CREATE TABLE n_chat_messages(message_id, author_id, channel_id, group_id, is_deleted);
      CREATE TABLE n_chat_channels(channel_id, group_id, is_private, is_deleted);
      CREATE TABLE n_groups(group_id, is_active, is_deleted);
      CREATE TABLE n_group_members(group_id, user_id, status, role);
      CREATE TABLE n_post_media(media_id, post_id);
      CREATE TABLE n_posts(post_id, author_id, is_deleted, visibility);
      INSERT INTO n_users VALUES (1,1,'active'),(2,1,'active'),(3,0,'disabled');
      INSERT INTO n_media_assets VALUES (7,'private/chat/a.txt','chat',1,'ready'),
        (8,'private/post/b.txt','post',1,'ready'), (9,'posts/files/c.txt','public',1,'ready');
    `);
    const select = db.prepare(query);
    const allowed = (media_id, viewer_id) => Boolean(select.get({ media_id, viewer_id }));
    assert.equal(allowed(7, 1), true);
    assert.equal(allowed(7, 2), false);
    assert.equal(allowed(9, 1), false);
    db.exec(`
      INSERT INTO n_chat_message_media VALUES (7,20);
      INSERT INTO n_chat_messages VALUES (20,1,30,40,0);
      INSERT INTO n_chat_channels VALUES (30,40,0,0);
      INSERT INTO n_groups VALUES (40,1,0);
      INSERT INTO n_group_members VALUES (40,2,'muted','member'),(40,3,'active','admin');
      INSERT INTO n_post_media VALUES (8,10);
      INSERT INTO n_posts VALUES (10,1,0,'followers');
    `);
    assert.equal(allowed(7, 1), false);
    assert.equal(allowed(7, 2), true);
    assert.equal(allowed(7, 3), false);
    assert.equal(allowed(8, 2), true);
    db.exec('INSERT INTO n_user_blocks VALUES (1,2)');
    assert.equal(allowed(7, 2), false);
    assert.equal(allowed(8, 2), false);
    db.exec('DELETE FROM n_user_blocks; UPDATE n_chat_channels SET is_private=1');
    assert.equal(allowed(7, 2), false);
    db.exec("UPDATE n_group_members SET role='moderator'; UPDATE n_posts SET visibility='public'");
    assert.equal(allowed(7, 2), true);
    assert.equal(allowed(8, 2), false);
    db.exec('UPDATE n_chat_messages SET is_deleted=1');
    assert.equal(allowed(7, 2), false);
  } finally {
    db.close();
  }
});

test('private download authorizes before opening storage and filters provider headers', async t => {
  const built = await build({
    stdin: { contents: "export { readPrivateMediaContent } from './server/services/v2/private-media'; export { corsHeadersForRequest } from './server/utils/cors';", resolveDir: root, loader: 'ts' },
    bundle: true, write: false, format: 'esm', platform: 'node',
    plugins: [{ name: 'private-media-adapters', setup(builder) {
      builder.onResolve({ filter: /^h3$/ }, () => ({ path: import.meta.resolve('h3'), external: true }));
      builder.onResolve({ filter: /^~\/server\/(storage|utils\/v2)$/ }, args => ({ path: args.path, namespace: 'fixture' }));
      builder.onResolve({ filter: /^~\/server\// }, args => ({ path: root + args.path.slice(2) + '.ts' }));
      builder.onLoad({ filter: /.*/, namespace: 'fixture' }, args => ({ contents: args.path.endsWith('/storage')
        ? 'export const getStorageProvider = () => globalThis.privateMediaFixture.provider;'
        : `
          import {createError} from 'h3';
          export const v2Throw = (statusCode, message) => { throw createError({statusCode,message}); };
          export const v2BadRequest = message => v2Throw(400,message);
          export const v2NotFound = message => v2Throw(404,message);
          export const v2ServerError = () => v2Throw(500,'server error');
          export const v2Auth = event => event.context.auth ?? v2Throw(401,'unauthorized');
          export const v2Connection = () => globalThis.privateMediaFixture.connection;
          export const v2One = (connection, query, binds) => connection.one(query, binds);
        `
      }));
    } }]
  });
  const { readPrivateMediaContent, corsHeadersForRequest } = await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);
  const preflight = {
    origin: 'https://web.example.test', allowedOrigins: ['https://web.example.test'],
    requestMethod: 'HEAD', requestHeaders: 'Authorization, Range'
  };
  const headers = corsHeadersForRequest({ ...preflight, path: '/api/v2/media/7/content' });
  assert.equal(headers['Access-Control-Allow-Methods'], 'GET,HEAD,OPTIONS');
  assert.match(headers['Access-Control-Expose-Headers'], /content-range/);
  assert.match(headers['Access-Control-Expose-Headers'], /x-request-id/i);
  assert.equal(corsHeadersForRequest({ ...preflight, path: '/api/v2/posts/7' }), null);
  const key = 'private/chat/42/example.txt';
  const events = [];
  let record;
  let directMedia = 'ready';
  globalThis.privateMediaFixture = {
    connection: {
      async one(sql, args) {
        if (sql === directSql.private_media_read) {
          assert.deepEqual(args, { viewer_id: 42, media_id: 7 });
          events.push('authorize');
          if (directMedia !== 'ready') throw Object.assign(new Error('missing direct media table'), { errorNum: 942 });
          return record;
        }
        if (sql === "SELECT USER AS USER_NAME, SYS_CONTEXT('USERENV','CURRENT_SCHEMA') AS SCHEMA_NAME FROM dual") {
          events.push('schema owner');
          return { USER_NAME: 'FIXTURE', SCHEMA_NAME: 'FIXTURE' };
        }
        if (sql === directSql.attachment_table_present) {
          events.push('table presence');
          return directMedia === 'absent' ? null : { PRESENT: 1 };
        }
        assert.equal(sql, query);
        assert.equal(directMedia, 'absent');
        assert.deepEqual(args, { viewer_id: 42, media_id: 7 });
        events.push('legacy authorize');
        return record;
      },
      async close() { events.push('close'); }
    },
    provider: {
      async readPrivateObject(foundKey, options) {
        assert.equal(foundKey, key);
        assert.equal(options.rangeHeader, 'bytes=0-1');
        events.push(options.headOnly ? 'head' : 'get');
        return {
          statusCode: options.headOnly ? 200 : 206,
          headers: {
            'Content-Length': options.headOnly ? '4' : '2',
            ...(options.headOnly ? {} : {'Content-Range': 'bytes 0-1/4'}),
            'Cache-Control': 'public, max-age=3600',
            'Location': 'https://storage.example.test/hidden',
          },
          stream: Readable.from(options.headOnly ? [] : [Buffer.from('ok')]),
        };
      }
    }
  };
  t.after(() => { delete globalThis.privateMediaFixture; });
  const app = createApp().use(eventHandler(event => {
    if (event.node.req.headers.authorization) event.context.auth = { userId: 42 };
  })).use(createRouter()
    .get('/api/v2/media/:id/content', eventHandler(readPrivateMediaContent))
    .head('/api/v2/media/:id/content', eventHandler(readPrivateMediaContent)));
  const server = createServer(toNodeListener(app));
  await new Promise((resolve, reject) => server.listen(0, '127.0.0.1', resolve).once('error', reject));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const url = `http://127.0.0.1:${server.address().port}/api/v2/media`;
  const request = (id, method, auth = true) => fetch(`${url}/${id}/content`, {
    method, headers: { Range: 'bytes=0-1', ...(auth ? { Authorization: 'Bearer fixture' } : {}) },
  });
  assert.equal((await request(7, 'GET', false)).status, 401);
  assert.equal((await request('07', 'GET')).status, 400);
  assert.deepEqual(events, []);
  assert.equal((await request(7, 'GET')).status, 404);
  record = { STORAGE_KEY: key, ACCESS_SCOPE: 'post' };
  assert.equal((await request(7, 'GET')).status, 404);
  assert.deepEqual(events.splice(0), ['authorize', 'close', 'authorize', 'close']);

  record = { STORAGE_KEY: key, ACCESS_SCOPE: 'chat' };
  const get = await request(7, 'GET');
  assert.equal(get.status, 206);
  assert.equal(get.headers.get('content-type'), 'application/octet-stream');
  assert.equal(get.headers.get('content-disposition'), 'attachment');
  assert.equal(get.headers.get('cache-control'), 'private, no-store');
  assert.equal(get.headers.get('location'), null);
  assert.equal(get.headers.get('content-range'), 'bytes 0-1/4');
  assert.equal(await get.text(), 'ok');
  const head = await request('%37', 'HEAD');
  assert.equal(head.status, 200);
  assert.equal(head.headers.get('content-length'), '4');
  assert.equal(head.headers.get('content-range'), null);
  assert.equal(await head.text(), '');
  assert.deepEqual(events.splice(0), ['authorize', 'close', 'get', 'authorize', 'close', 'head']);

  directMedia = 'absent';
  assert.equal((await request(7, 'HEAD')).status, 200);
  assert.deepEqual(events.splice(0), ['authorize', 'schema owner', 'table presence', 'legacy authorize', 'close', 'head']);
  directMedia = 'present-but-unavailable';
  assert.equal((await request(7, 'HEAD')).status, 503);
  assert.deepEqual(events, ['authorize', 'schema owner', 'table presence', 'close']);
});
