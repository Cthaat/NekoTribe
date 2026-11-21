import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';

const source = path => readFileSync(new URL(path, import.meta.url), 'utf8');
const nuxt = source('../server/services/v2/groups.ts');
const statement = name => nuxt.match(new RegExp('const ' + name + ' = `([\\s\\S]+?)`;'))[1];
const preference = statement('groupPreferenceSql');
const audit = statement('groupAuditLogsSql');

test('group admin statements match across native worktrees', {
  skip: !['../../go/internal/server/group_admin.go', '../../rust/src/group_admin.rs']
    .every(path => existsSync(new URL(path, import.meta.url)))
}, () => {
  const go = source('../../go/internal/server/group_admin.go');
  const rust = source('../../rust/src/group_admin.rs');
  for (const [sql, g, r] of [
    [preference, 'groupPreferenceSQL', 'PREFERENCE'],
    [statement('saveGroupPreferenceSql'), 'saveGroupPreferenceSQL', 'MERGE'],
    [audit, 'groupAuditLogsSQL', 'AUDIT']
  ]) {
    assert.equal(go.match(new RegExp('const ' + g + ' = `([\\s\\S]+?)`'))[1], sql);
    assert.equal(rust.match(new RegExp('const ' + r + ':\\s*&str\\s*=\\s*"([\\s\\S]+?)";'))[1], sql);
  }
});

test('preferences are member-scoped and audit pagination is private and stable', t => {
  const db = new DatabaseSync(':memory:');
  t.after(() => db.close());
  db.exec(`
    CREATE TABLE n_groups(group_id,is_active,is_deleted,created_at);
    CREATE TABLE n_group_members(group_id,user_id,status,role);
    CREATE TABLE n_group_notification_preferences(group_id,user_id,is_enabled,updated_at);
    CREATE TABLE n_group_audit_logs(log_id,group_id,actor_id,target_user_id,target_post_id,target_comment_id,action,details,ip_address,created_at);
    INSERT INTO n_groups VALUES (7,1,0,'creation'),(8,0,1,'creation'),(9,1,0,'creation');
    INSERT INTO n_group_members VALUES (7,42,'active','moderator'),(7,43,'active','member'),(7,44,'pending','owner'),
      (7,45,'muted','admin'),(8,42,'active','owner'),(9,42,'active','admin');
    INSERT INTO n_group_notification_preferences VALUES (7,43,0,'saved'),(7,44,0,'stale'),(8,42,0,'stale');
    INSERT INTO n_group_audit_logs VALUES
      (1,7,20,NULL,NULL,NULL,'create_group',NULL,NULL,'same'),
      (2,7,21,20,NULL,NULL,'change_role','{"from":"member"}',NULL,'same'),
      (3,8,21,20,NULL,NULL,'change_role',NULL,NULL,'same');
  `);
  const prefs = db.prepare(preference);
  const pref = (user_id, group_id = 7) => prefs.get({ user_id, group_id });
  assert.equal(pref(42).is_enabled, 1);
  assert.equal(pref(42).updated_at, null);
  assert.equal(pref(43).is_enabled, 0);
  assert.equal(pref(43).updated_at, 'saved');
  assert.equal(pref(44).member_id, null);
  assert.equal(pref(42, 8), undefined);
  const logs = db.prepare(audit);
  const page = (overrides = {}) => logs.all({ user_id: 42, group_id: 7, start_row: 1, end_row: 2, ...overrides });
  assert.deepEqual(page().map(row => row.log_id), [2, 1]);
  assert.equal(page()[0].actor_id, 21);
  for (const user_id of [43, 44, 45, 46]) {
    const [row] = page({ user_id });
    assert.equal(row.group_exists, 1);
    assert.equal(row.scope_allowed, 0);
    assert.equal(row.total, 0);
    assert.equal(row.log_id, null);
  }
  const [overflow] = page({ start_row: 10, end_row: 12 });
  assert.equal(overflow.total, 2);
  assert.equal(overflow.log_id, null);
  assert.equal(page({ group_id: 8 })[0].group_exists, 0);
  assert.equal(page({ group_id: 9 })[0].total, 0);
});
