import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';

const service = readFileSync(new URL('../server/services/v2/groups.ts', import.meta.url), 'utf8');
const sql = service.match(/const groupMemberListSql = `([\s\S]+?)`;/)[1];

test('member list authorization and pagination use the same filtered rows', t => {
  const db = new DatabaseSync(':memory:');
  t.after(() => db.close());
  db.exec(`
    CREATE TABLE n_groups (group_id, privacy, is_active, is_deleted);
    CREATE TABLE n_group_members (group_id, user_id, role, status);
    CREATE TABLE v_user_profile_public (user_id, is_active);
    CREATE TABLE v_group_member_details (group_id, member_id, user_id, role, role_desc, status, nickname, joined_at, mute_until);
    INSERT INTO n_groups VALUES (7,'public',1,0),(8,'private',1,0),(9,'public',0,0),(10,'public',1,1);
    INSERT INTO n_group_members VALUES (7,100,'admin','active'),(7,101,'admin','muted'),(7,102,'member','banned'),
      (8,103,'member','pending'),(8,104,'member','muted');
    INSERT INTO v_user_profile_public VALUES (100,1),(101,1),(102,1),(105,1),(106,1),(107,1),(108,0);
    INSERT INTO v_group_member_details VALUES
      (7,21,100,'admin','管理员','active',NULL,'2026-11-01',NULL),
      (7,23,106,'member','成员','active',NULL,'2026-11-02',NULL),
      (7,22,101,'admin','管理员','muted','alias','2026-11-02','2026-11-30'),
      (7,24,102,'member','成员','banned',NULL,'2026-11-03',NULL),
      (7,25,105,'member','成员','pending',NULL,'2026-11-03',NULL),
      (7,26,107,'owner','群主','active',NULL,'2026-11-03',NULL),
      (7,27,108,'member','成员','active',NULL,'2026-11-03',NULL);
  `);
  const query = db.prepare(sql);
  const list = (viewer, overrides = {}) => query.all({
    viewer_id: viewer, group_id: 7, role_filter: null, status_filter: null,
    start_row: 1, end_row: 20, ...overrides
  });
  const publicList = list(200);
  assert.deepEqual(publicList.map(row => row.member_id), [26, 21, 22, 23]);
  assert.equal(publicList[0].total, 4);
  assert.equal(publicList[2].mute_until, null);
  assert.equal(list(101)[2].mute_until, '2026-11-30');
  assert.equal(list(100)[2].mute_until, '2026-11-30');
  assert.equal(list(102)[0].access_level, 0);
  assert.equal(list(103, { group_id: 8 })[0].access_level, 0);
  assert.equal(list(104, { group_id: 8 })[0].access_level, 1);
  assert.deepEqual(list(200, { group_id: 9 }), []);
  assert.deepEqual(list(200, { group_id: 10 }), []);
  assert.equal(list(101, { status_filter: 'pending' })[0].total, 0);
  assert.equal(list(100, { role_filter: 'member', status_filter: 'pending' })[0].member_id, 25);
  const emptyPage = list(100, { role_filter: 'member', start_row: 9, end_row: 11 });
  assert.equal(emptyPage[0].member_id, null);
  assert.equal(emptyPage[0].total, 3);
});
