import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';

const source = readFileSync(new URL('../server/services/v2/groups.ts', import.meta.url), 'utf8');
const sql = source.match(/const groupInviteListSql = `([\s\S]*?)`;/)[1];

test('group invite visibility and filtered pagination share a statement', t => {
  const db = new DatabaseSync(':memory:');
  t.after(() => db.close());
  db.exec(`
    CREATE TABLE n_groups (group_id, description, is_active, is_deleted);
    CREATE TABLE n_group_members (group_id, user_id, status, role);
    CREATE TABLE v_group_invite_details (
      invite_id, invite_code, status, message, max_uses, used_count, expires_at, created_at,
      group_id, group_name, group_slug, group_avatar_url, group_privacy,
      group_member_count, inviter_id, invitee_id, is_valid
    );
    INSERT INTO n_groups VALUES (7,'private room',1,0),(8,'inactive room',0,0);
    INSERT INTO n_group_members VALUES (7,42,'active','moderator'),(7,43,'muted','admin'),(7,44,'active','member');
    INSERT INTO v_group_invite_details VALUES
      (7,'ABC','pending',NULL,3,2,NULL,'2026-11-16',7,'Cat','cat',NULL,'private',2,42,NULL,1),
      (8,NULL,'pending',NULL,1,0,NULL,'2026-11-16',7,'Cat','cat',NULL,'private',2,42,41,1),
      (9,'XYZ','accepted',NULL,1,1,NULL,'2026-11-15',7,'Cat','cat',NULL,'private',2,42,NULL,0);
  `);
  const list = db.prepare(sql);
  const get = (overrides = {}) => list.all({
    group_id: 7, viewer_id: 42, status_filter: null, start_row: 1, end_row: 20, ...overrides
  });
  assert.deepEqual(get().map(row => row.invite_id), [8, 7, 9]);
  assert.deepEqual(get({ status_filter: 'pending' }).map(row => row.invite_id), [8, 7]);
  assert.equal(get({ status_filter: 'pending', start_row: 10, end_row: 20 })[0].total, 2);
  assert.equal(get({ start_row: 10, end_row: 20 })[0].invite_id, null);
  for (const viewer_id of [43, 44, 45]) {
    const [row] = get({ viewer_id });
    assert.equal(row.allowed, 0);
    assert.equal(row.invite_code, null);
    assert.equal(row.total, 0);
  }
  assert.deepEqual(get({ group_id: 8 }), []);
});

test('inbox returns only the recipient’s usable invitations', t => {
  const db = new DatabaseSync(':memory:');
  t.after(() => db.close());
  db.exec(`
    CREATE TABLE n_groups (group_id, description, is_active, is_deleted);
    CREATE TABLE v_group_invite_details (
      invite_id, invite_code, status, message, max_uses, used_count, expires_at, created_at,
      group_id, group_name, group_slug, group_avatar_url, group_privacy,
      group_member_count, inviter_id, invitee_id
    );
    INSERT INTO n_groups VALUES (7,'private room',1,0),(8,'gone',0,1);
    INSERT INTO v_group_invite_details VALUES
      (1,NULL,'pending',NULL,1,0,NULL,'2026-11-15',7,'Cat','cat',NULL,'private',2,9,42),
      (2,NULL,'pending',NULL,1,0,NULL,'2026-11-15',7,'Cat','cat',NULL,'private',2,9,42),
      (3,NULL,'pending',NULL,1,0,NULL,'2026-11-16',7,'Cat','cat',NULL,'private',2,9,21),
      (4,NULL,'pending',NULL,1,1,NULL,'2026-11-16',7,'Cat','cat',NULL,'private',2,9,42),
      (5,NULL,'pending',NULL,1,0,'2000-01-01','2026-11-16',7,'Cat','cat',NULL,'private',2,9,42),
      (6,NULL,'pending',NULL,1,0,NULL,'2026-11-16',8,'Gone','gone',NULL,'private',2,9,42),
      (7,'LINK','pending',NULL,5,0,NULL,'2026-11-16',7,'Cat','cat',NULL,'private',2,9,NULL),
      (8,NULL,'rejected',NULL,1,0,NULL,'2026-11-16',7,'Cat','cat',NULL,'private',2,9,42);
  `);
  const inboxSql = source.match(/const groupInviteInboxSql = `([\s\S]*?)`;/)[1];
  const query = db.prepare(inboxSql.replaceAll('NVL(', 'COALESCE(').replaceAll('SYSTIMESTAMP', 'CURRENT_TIMESTAMP'));
  const list = (viewer_id, start_row, end_row, invite_id = 0) =>
    query.all({ viewer_id, start_row, end_row, invite_id });
  assert.deepEqual(list(42, 1, 20).map(row => row.invite_id), [2, 1]);
  assert.equal(list(42, 10, 20)[0].total, 2);
  assert.equal(list(42, 10, 20)[0].invite_id, null);
  assert.deepEqual(list(21, 1, 20).map(row => row.invite_id), [3]);
  assert.equal(list(10, 1, 20)[0].total, 0);
  assert.deepEqual(list(42, 1, 1, 1).map(row => row.invite_id), [1]);
  assert.equal(list(42, 2, 2, 1)[0].total, 1);
  assert.equal(list(42, 2, 2, 1)[0].invite_id, null);
  for (const id of [3, 4, 5, 6, 7, 8, 99]) {
    const [row] = list(42, 1, 20, id);
    assert.equal(row.total, 0, `unavailable invite ${id}`);
    assert.equal(row.invite_id, null);
  }
});

test('native inbox queries match the reviewed Nuxt query in the four-tree workspace', t => {
  const go = new URL('../../go/internal/server/group_invite_response.go', import.meta.url);
  const rust = new URL('../../rust/src/group_invite_reads.rs', import.meta.url);
  if (!existsSync(go) || !existsSync(rust)) return t.skip('Native worktrees unavailable');
  const inboxSql = source.match(/const groupInviteInboxSql = `([\s\S]*?)`;/)[1].replaceAll('\r\n', '\n');
  assert.equal(readFileSync(go, 'utf8').match(/const groupInviteInboxSQL = `([\s\S]*?)`/)[1].replaceAll('\r\n', '\n'), inboxSql);
  assert.equal(JSON.parse(readFileSync(rust, 'utf8').match(/const INBOX: &str = ("[^"]+");/)[1]), inboxSql);
});
