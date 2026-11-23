import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';
import policy from '../specifications/requirements/direct-message-extras.json' with { type: 'json' };
import legacy from '../specifications/requirements/media-private-read.json' with { type: 'json' };

const built = await build({
  stdin: {
    contents: `export * from './server/services/v2/direct-message-extras'; export * from './server/services/v2/direct-media-links';`,
    resolveDir: fileURLToPath(new URL('../', import.meta.url)),
  },
  bundle: true, write: false, platform: 'node', format: 'esm',
  plugins: [{ name: 'direct-message-oracle-fixture', setup(builder) {
    const stubs = {
      '~/server/models/v2': 'export const v2MapMedia = row => ({ media_id: row.MEDIA_ID, public_url: row.PUBLIC_URL, thumbnail_url: row.THUMBNAIL_URL });',
      '~/server/storage/local-path': `export const normalizeLocalStorageKey = key => key;`,
      '~/server/utils/auth-entry-errors': 'export const v2ServiceUnavailable = () => { throw Object.assign(new Error(), {statusCode:503}); };',
      '~/server/utils/v2': `
        const fail = (statusCode, message) => { throw Object.assign(new Error(message), { statusCode }); };
        export const v2BadRequest = message => fail(400,message), v2NotFound = message => fail(404,message), v2ServerError = () => fail(500);
        export const v2One = (db,sql,binds) => db.one(sql,binds), v2Rows = (db,sql,binds) => db.rows(sql,binds),
          v2Execute = (db,sql,binds) => db.write(sql,binds), v2RouterParam = (event,key) => event[key];
        export const v2Number = Number, v2String = String, v2Boolean = value => value === 1;
      `,
    };
    builder.onResolve({ filter: /^~\// }, ({ path }) => ({ path, namespace: 'fixture' }));
    builder.onLoad({ filter: /.*/, namespace: 'fixture' }, ({ path }) => ({ contents: stubs[path] }));
  }}],
});
const api = await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);
const { sql } = policy;
const missing = () => Object.assign(new Error('table absent'), { errorNum: 942 });

test('attachment-only messages use owned chat uploads, retain send order and hydrate private links', async () => {
  const input = api.directMessageInput({ media_ids: [30, 20], reply_to_message_id: 9 });
  assert.equal(input.content, '');
  const locked = [], inserted = [];
  const connection = {
    one(query, bind) {
      if (query === sql.asset_lock) {
        assert.equal(bind.user_id, 7);
        locked.push(bind.media_id);
        return bind.media_id !== 40 ? { STORAGE_KEY: 'private/chat/chat.png' } : null;
      }
      assert.equal(query, sql.asset_free);
      return { FREE: 1 };
    },
    write(query, bind) { inserted.push([query, bind]); return 1; },
    rows(query, bind) {
      assert.equal(bind.message_ids, '[10]');
      if (query === sql.list_media) return [{ MESSAGE_ID: 10, MEDIA_ID: 30 }, { MESSAGE_ID: 10, MEDIA_ID: 20 }];
      if (query === sql.list_replies) return [{ MESSAGE_ID: 10, REPLY_ID: 9, REPLY_CONTENT: 'hello', REPLY_AUTHOR_NAME: 'member' }];
      assert.equal(query, sql.list_reactions);
      return [{ MESSAGE_ID: 10, EMOJI: '👍', REACTION_COUNT: 1, REACTED_BY_ME: Number(bind.viewer_id === 7) }];
    },
  };
  await api.lockDirectAttachments(connection, 7, input.mediaIds);
  assert.deepEqual(locked, [20, 30]);
  await api.attachDirectMessageExtras(connection, 10, input.mediaIds, input.replyId);
  assert.deepEqual(inserted, [[sql.insert_reply, { message_id: 10, reply_to_message_id: 9 }],
    [sql.insert_media, { message_id: 10, media_id: 30, position: 1 }], [sql.insert_media, { message_id: 10, media_id: 20, position: 2 }]]);
  const author = { message_id: 10 }, recipient = { message_id: 10 };
  await api.hydrateDirectMessageExtras(connection, 7, [author]);
  await api.hydrateDirectMessageExtras(connection, 8, [recipient]);
  assert.deepEqual(author.media.map(item => item.public_url), ['/api/v2/media/30/content', '/api/v2/media/20/content']);
  assert.equal(author.reply_to.message_id, 9);
  assert.equal(author.reactions[0].reacted_by_me, true);
  assert.equal(recipient.reactions[0].reacted_by_me, false);
  await assert.rejects(api.lockDirectAttachments(connection, 7, [40]), { statusCode: 404 });
  assert.throws(() => api.directMessageInput({ media_ids: [20, 20] }), { statusCode: 400 });
});

test('modern private download denials and partial schema failures never open legacy media access', async () => {
  const calls = [];
  let state = 'denied';
  const connection = {
    one(query, bind) {
      calls.push(query);
      if (query === sql.private_media_read) {
        assert.deepEqual(bind, { viewer_id: 8, media_id: 20 });
        if (state === 'denied') return null;
        throw missing();
      }
      if (query.includes('CURRENT_SCHEMA')) return { USER_NAME: 'APP', SCHEMA_NAME: 'APP' };
      if (query === sql.attachment_table_present || query === sql.any_extras_table_present) {
        return state === 'legacy' ? null : { PRESENT: 1 };
      }
      assert.equal(query, legacy.query);
      return { STORAGE_KEY: 'private/chat/legacy.png' };
    },
    rows() { throw missing(); },
  };
  assert.equal(await api.readPrivateMediaAccess(connection, 8, 20), null);
  assert.deepEqual(calls, [sql.private_media_read]);
  state = 'partial';
  await assert.rejects(api.readPrivateMediaAccess(connection, 8, 20), { errorNum: 942 });
  await assert.rejects(api.hydrateDirectMessageExtras(connection, 8, [{ message_id: 10 }], true), { statusCode: 503 });
  assert(!calls.includes(legacy.query));
  state = 'legacy';
  assert.equal((await api.readPrivateMediaAccess(connection, 8, 20)).STORAGE_KEY, 'private/chat/legacy.png');
  await api.hydrateDirectMessageExtras(connection, 8, [{ message_id: 10 }], true);
  await assert.rejects(api.hydrateDirectMessageExtras(connection, 8, [{ message_id: 10 }]), { statusCode: 503 });
});
