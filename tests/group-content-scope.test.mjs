import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';
import ts from 'typescript';

const policy = JSON.parse(readFileSync(new URL('../specifications/requirements/moderation-publish-policy.json', import.meta.url)));
const media = JSON.parse(readFileSync(new URL('../specifications/requirements/media-delete-references.json', import.meta.url)));
const avatarKey = 'posts/images/42/2026/11/12345678-1234-4321-8765-123456789abc.png';
const coverKey = 'posts/images/42/2026/11/abcdefab-1234-4321-8765-123456789abc.png';
const attachmentKey = 'posts/files/42/2026/11/abcdefac-1234-4321-8765-123456789abc.pdf';
const policySource = readFileSync(new URL('../server/services/v2/moderation-publish-policy.ts', import.meta.url), 'utf8');
const policyModule = ts.transpileModule(policySource, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, esModuleInterop: true }
}).outputText;

const source = readFileSync(new URL('../server/services/v2/groups.ts', import.meta.url), 'utf8');
const { outputText } = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, esModuleInterop: true }
});

function fixture({ active = true, visible = true, writeError = false, muted = false, missingImage = false, blockedAfterWrite = false } = {}) {
  const events = [];
  const groupWrites = [];
  const failure = status => () => { throw Object.assign(new Error(String(status)), { status }); };
  const utils = {
    v2Auth: () => ({ userId: 42 }),
    v2BadRequest: failure(400),
    v2NotFound: failure(404),
    v2Unprocessable: failure(422),
    v2ServerError: failure(500),
    v2Forbidden: message => { throw Object.assign(new Error(message), { status: 403 }); },
    v2RouterParam: (event, name) => event[name],
    v2Boolean: value => value === 1,
    v2Number: Number,
    v2Ok: data => data,
    v2Null: () => null,
    v2Body: event => event.body ?? {},
    v2RequiredString: (_, key) => key,
    v2RequiredNumber: Number,
    v2StringOrNull: value => value || null,
    v2NextId: async () => 7,
    v2Rows: async (_, sql, binds) => {
      assert.equal(sql, media.lookupGroupImages);
      events.push('image lookup');
      return [
        { MEDIA_ID: 2, STORAGE_KEY: coverKey },
        { MEDIA_ID: 5, STORAGE_KEY: avatarKey },
        { MEDIA_ID: 1, STORAGE_KEY: attachmentKey }
      ].filter(row => [binds.first_key, binds.second_key].includes(row.STORAGE_KEY));
    },
    v2One: async (_, sql, binds) => {
      if (sql === media.lockGroupImage) {
        events.push(`image lock ${binds.media_id}`);
        return missingImage && binds.media_id === 2 ? null : { PUBLIC_URL: `/storage/${binds.storage_key}` };
      }
      if (sql.includes('SELECT owner_id, privacy, join_approval')) {
        events.push('group lock');
        return active ? { OWNER_ID: 42, IS_ACTIVE: 1, IS_DELETED: 0 } : null;
      }
      if (sql.startsWith('SELECT role,status FROM n_group_members')) return { ROLE: 'owner', STATUS: 'active' };
      if (sql === policy.sql.lock) {
        assert.equal(binds.user_id, 42);
        events.push('account lock');
        return { USER_ID: 42 };
      }
      if (sql === policy.sql.allowed) {
        events.push('publish access');
        return { ALLOWED: muted ? 0 : 1 };
      }
      if (sql.endsWith('FOR UPDATE')) {
        events.push('lock');
        return active ? { GROUP_ID: 7 } : null;
      }
      if (sql.includes('fn_can_view_group')) {
        events.push('access');
        return { ALLOWED: visible ? 1 : 0 };
      }
      if (sql.includes('fn_can_post_in_group')) return { ALLOWED: 1 };
      if (sql.includes('fn_has_group_permission')) return { ALLOWED: 1 };
      if (sql.startsWith('SELECT 1 AS visible FROM n_users')) {
        assert.equal(binds.author_id, 42);
        assert.equal(binds.viewer_id, 42);
        events.push('author visibility');
        return blockedAfterWrite && events.includes('write') ? null : {VISIBLE:1};
      }
      if (sql.includes('likes_count')) return { LIKES_COUNT: 3 };
      if (sql.includes('FROM n_group_posts')) {
        events.push('post');
        assert.match(sql, /group_id=:group_id AND post_id=:post_id AND is_deleted=0/);
        return binds.group_id === 7 && binds.post_id === 5 ? { AUTHOR_ID: 42 } : null;
      }
      if (sql.includes('FROM n_group_comments')) {
        events.push('comment');
        assert.match(sql, /post_id=:post_id AND comment_id=:comment_id AND is_deleted=0/);
        return binds.post_id === 5 && binds.comment_id === 4 ? { AUTHOR_ID: 42 } : null;
      }
      throw new Error(sql);
    },
    v2Execute: async (_, sql, binds, autoCommit) => {
      events.push('write');
      if (/^\s*(INSERT INTO|UPDATE) n_groups\b/.test(sql)) groupWrites.push(binds);
      assert.equal(autoCommit, false, sql);
      if (writeError) throw new Error('failed write');
      return 1;
    }
  };
  const deps = {
    '../../../specifications/requirements/media-delete-references.json': media,
    '~/server/storage': { managedPublicUrlToStorageKey: () => null },
    '~/server/utils/v2': utils,
    '~/server/database/readiness': { requireFeatureSchema: async () => {} },
    '~/server/models/v2': {
      v2RequireGroup: async () => {
        events.push('readback');
        return { group_id: 7 };
      }
    },
    h3: {
      readRawBody: event => JSON.stringify(event.body),
      setResponseHeader: (event, name, value) => { event[name] = value; }
    }
  };
  const policyExports = {};
  vm.runInNewContext(policyModule, {
    exports: policyExports,
    require: name => name === '~/server/utils/v2' ? utils : policy
  });
  deps['./moderation-publish-policy'] = policyExports;
  deps['./post-polls'] = { readPollCreation: () => undefined, readPostPoll: async () => undefined };
  deps['./post-markdown'] = { readPostMarkdownInput: () => undefined, readPostMarkdown: async () => undefined };
  const exports = {};
  vm.runInNewContext(outputText, { Buffer, exports, require: name => deps[name] ?? {} });
  const connection = {
    commit: async () => { events.push('commit'); },
    rollback: async () => { events.push('rollback'); }
  };
  const event = { id: '7', post_id: '5', comment_id: '4' };
  return { api: exports, event, connection, events, groupWrites };
}

test('group publishing rejects a muted account before writes and rolls back', async () => {
  for (const [action, prefix] of [['v2CreateGroupPost', []], ['v2CreateGroupComment', ['post','author visibility']]]) {
    const { api, event, connection, events } = fixture({ muted: true });
    event.body = { content: 'hello' };
    await assert.rejects(api[action](event, connection), { status: 403, message: policy.message });
    assert.deepEqual(events, ['lock', 'access', ...prefix, 'account lock', 'publish access', 'rollback']);
  }
});

test('group comment reactions commit after checking all three path segments', async () => {
  const { api, event, connection, events } = fixture();
  for (const liked of [true, false]) {
    const result = await api.v2LikeGroupComment(event, connection, liked);
    assert.equal(result.comment_id, 4);
    assert.equal(result.is_liked, liked);
  }
  const expected = ['lock', 'access', 'post', 'author visibility', 'comment', 'write', 'author visibility', 'commit'];
  assert.deepEqual(events, [...expected, ...expected]);
  assert.equal(event['Cache-Control'], 'private, no-store');
});

test('a group reaction rolls back if its post author becomes hidden', async () => {
  const { api, event, connection, events } = fixture({blockedAfterWrite:true});
  await assert.rejects(api.v2LikeGroupComment(event, connection, true), {status:404});
  assert.deepEqual(events, ['lock', 'access', 'post', 'author visibility', 'comment', 'write', 'author visibility', 'rollback']);
});

test('group post reactions and pin roll back on visibility loss, while unpin and delete can commit', async () => {
  for (const [run, checked] of [
    [(api,event,conn)=>api.v2LikeGroupPost(event,conn,true),true],
    [(api,event,conn)=>api.v2LikeGroupPost(event,conn,false),true],
    [(api,event,conn)=>api.v2SetGroupPostPin({...event,body:{is_pinned:true}},conn),true],
    [(api,event,conn)=>api.v2SetGroupPostPin({...event,body:{is_pinned:false}},conn),false],
    [(api,event,conn)=>api.v2DeleteGroupPost(event,conn),false]
  ]) {
    const {api,event,connection,events}=fixture({blockedAfterWrite:true});
    if(checked) {
      await assert.rejects(run(api,event,connection),{status:404});
      assert.deepEqual(events.slice(-3),['write','author visibility','rollback']);
    } else {
      await run(api,event,connection);
      assert.deepEqual(events.slice(-2),['write','commit']);
      assert(!events.includes('author visibility'));
    }
  }
});

test('inactive or inaccessible groups and wrong ancestors cannot change content', async () => {
  for (const [options, update, sequence] of [
    [{ active: false }, {}, ['lock', 'rollback']],
    [{ visible: false }, {}, ['lock', 'access', 'rollback']],
    [{}, { id: '8' }, ['lock', 'access', 'post', 'rollback']],
    [{}, { comment_id: '9' }, ['lock', 'access', 'post', 'comment', 'rollback']]
  ]) {
    const { api, event, connection, events } = fixture(options);
    await assert.rejects(api.v2DeleteGroupComment({ ...event, ...update }, connection), { status: 404 });
    assert.deepEqual(events, sequence);
  }
});

test('unsafe IDs fail before locking and failed writes roll back', async () => {
  const { api, event, connection, events } = fixture({ writeError: true });
  await assert.rejects(api.v2LikeGroupPost({ ...event, post_id: '9007199254740992' }, connection, true), { status: 400 });
  assert.deepEqual(events, []);
  await assert.rejects(api.v2DeleteGroupPost(event, connection), /failed write/);
  assert.deepEqual(events, ['lock', 'access', 'post', 'write', 'rollback']);
});

test('a reply to a comment outside the path post cannot be created', async () => {
  const { api, event, connection, events } = fixture();
  event.body = { content: 'reply', parent_comment_id: 9 };
  await assert.rejects(api.v2CreateGroupComment(event, connection), { status: 404 });
  assert.deepEqual(events, ['lock', 'access', 'post', 'author visibility', 'comment', 'rollback']);
});

test('group creation commits after group, owner, normalized tag, audit and readback', async () => {
  const { api, event, connection, events } = fixture();
  event.body = { name: ' Cat ', tags: ['#Rust', 'rust'] };
  const group = await api.v2CreateGroup(event, connection);
  assert.equal(group.group_id, 7);
  assert.deepEqual(events, ['write', 'write', 'write', 'write', 'readback', 'commit']);
});

test('group create and edit lock ordered images and reject an image deleted before the lock', async () => {
  for (const method of ['v2CreateGroup', 'v2PatchGroup']) {
    for (const missingImage of [false, true]) {
      const { api, event, connection, events, groupWrites } = fixture({ missingImage });
      event.body = {
        name: 'Cat', avatar_url: `https://old.test/uploads/${avatarKey}?preview=1`,
        cover_url: `/storage/${coverKey}`
      };
      if (missingImage) {
        await assert.rejects(api[method](event, connection), { status: 400 });
        assert.equal(groupWrites.length, 0);
        assert.deepEqual(events.slice(-3), ['image lookup', 'image lock 2', 'rollback']);
      } else {
        await api[method](event, connection);
        assert.deepEqual(events.filter(event => event.startsWith('image')), ['image lookup', 'image lock 2', 'image lock 5']);
        assert.ok(events.indexOf('image lock 5') < events.indexOf('write'));
        assert.equal(events.at(-1), 'commit');
        assert.equal(groupWrites[0].avatar_url, `/storage/${avatarKey}`);
        assert.equal(groupWrites[0].cover_url, `/storage/${coverKey}`);
      }
    }
  }
});

test('group post writes reject invalid body fields before acquiring the lock', async () => {
  const { api, event, connection, events } = fixture();
  await assert.rejects(api.v2CreateGroupPost({ ...event, body: { content: 5 } }, connection), { status: 400 });
  await assert.rejects(api.v2CreateGroupPost({ ...event, body: { content: 'test', is_announcement: 1 } }, connection), { status: 400 });
  await assert.rejects(api.v2SetGroupPostPin({ ...event, body: { is_pinned: 'true' } }, connection), { status: 400 });
  await assert.rejects(api.v2DeleteGroupPost({ ...event, body: { reason: '猫'.repeat(67) } }, connection), { status: 400 });
  assert.deepEqual(events, []);
});

test('group post creation locks all managed attachments by id before writing', async () => {
  const { api, event, connection, events } = fixture({ missingImage: true });
  event.body = {
    content: 'test',
    media_urls: [`/storage/${avatarKey}`, `/uploads/${coverKey}`, `/upload/${attachmentKey}`, `/upload/${avatarKey}`]
  };
  await assert.rejects(api.v2CreateGroupPost(event, connection), { status: 400 });
  assert.deepEqual(events.slice(-5), ['image lookup', 'image lookup', 'image lock 1', 'image lock 2', 'rollback']);
  assert.ok(!events.includes('write'));
});

test('group comment replies require safe IDs and the actual parent author', async () => {
  const { api, event, connection, events } = fixture();
  await assert.rejects(
    api.v2CreateGroupComment({ ...event, body: { content: 'test', parent_comment_id: '4' } }, connection),
    { status: 400 }
  );
  assert.deepEqual(events, []);
  await assert.rejects(
    api.v2CreateGroupComment({ ...event, body: { content: 'test', parent_comment_id: 4, reply_to_user_id: 20 } }, connection),
    { status: 422 }
  );
  assert.deepEqual(events, ['lock', 'access', 'post', 'author visibility', 'comment', 'rollback']);
});
