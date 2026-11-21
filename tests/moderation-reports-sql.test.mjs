import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { test } from 'node:test';

const { sql } = JSON.parse(readFileSync(new URL('../specifications/requirements/moderation-reports.json', import.meta.url)));

function withReports(callback) {
  const db = new DatabaseSync(':memory:');
  try {
    db.exec(`
      CREATE TABLE n_moderation_reports (
        report_id, target_type, target_id, reporter_user_id, reason, description, evidence_url,
        status, priority, handled_by, created_at, updated_at, resolved_at
      );
      INSERT INTO n_moderation_reports VALUES
        (11,'post',5,7,'spam',NULL,NULL,'pending','normal',NULL,'2026-11-01','2026-11-01',NULL),
        (12,'post',6,8,'spam','detail','https://example.test','pending','high',NULL,'2026-11-01','2026-11-01',NULL),
        (13,'user',9,8,'hate',NULL,NULL,'resolved','normal',42,'2026-11-02','2026-11-02','2026-11-02');
    `);
    callback(db);
  } finally { db.close(); }
}

test('report queue filters consistently, breaks ties by ID and keeps totals beyond the last page', () => {
  withReports(db => {
    const list = db.prepare(sql.list.replace(/TO_CHAR\(FROM_TZ\((r\.\w+), SESSIONTIMEZONE\) AT TIME ZONE 'UTC', '[^']+'\)/g, '$1'));
    const binds = { status: 'pending', reason: 'spam', target_type: 'post', start_row: 1, end_row: 2 };
    assert.deepEqual(list.all(binds).map(row => [row.report_id, row.total]), [[12, 2], [11, 2]]);
    assert.deepEqual(list.all({ ...binds, start_row: 3, end_row: 4 }).map(row => [row.report_id, row.total]), [[null, 2]]);
    assert.deepEqual(list.all({ ...binds, status: null, reason: null, target_type: 'user' }).map(row => row.report_id), [13]);
    assert.equal(list.get({ ...binds, reason: 'adult' }).total, 0);
  });
});

test('submission target queries require visibility and a live parent for comments', () => {
  const { create } = JSON.parse(readFileSync(new URL('../specifications/requirements/moderation-reports.json', import.meta.url)));
  const db = new DatabaseSync(':memory:');
  try {
    db.exec(`
      CREATE TABLE n_posts(post_id, is_deleted);
      CREATE TABLE n_comments(comment_id, post_id, is_deleted);
      CREATE TABLE n_users(user_id, is_active);
      CREATE TABLE n_groups(group_id, is_active, is_deleted, privacy);
      CREATE TABLE n_group_posts(post_id, group_id, is_deleted);
      CREATE TABLE n_group_comments(comment_id, post_id, is_deleted);
      CREATE TABLE n_group_members(group_id, user_id, status);
      INSERT INTO n_posts VALUES (1,0),(2,0),(3,1);
      INSERT INTO n_comments VALUES (1,1,0),(2,2,0),(3,3,0),(4,1,1);
      INSERT INTO n_users VALUES (1,1),(2,1),(3,0);
      INSERT INTO n_groups VALUES (1,1,0,'public'),(2,1,0,'private'),(3,0,0,'public'),(4,1,1,'public');
      INSERT INTO n_group_members VALUES (2,42,'active'),(2,46,'pending');
      INSERT INTO n_group_posts VALUES (1,1,0),(2,2,0),(3,1,1),(4,3,0),(5,4,0);
      INSERT INTO n_group_comments VALUES (1,1,0),(2,2,0),(3,3,0),(4,1,1);
    `);
    db.function('fn_can_view_post', (viewer, id) => Number(id === 1 || (id === 2 && viewer === 42)));
    db.function('fn_get_user_relationship', (_viewer, id) => id === 2 ? 'blocked_by' : 'none');
    const visible = Object.fromEntries(Object.entries(create.targets).map(([kind, sql]) => {
      assert.match(sql, / FOR UPDATE$/);
      return [kind, db.prepare(sql.replace(/ FOR UPDATE$/, ''))];
    }));
    const cases = [
      ['post',1,46,true], ['post',2,46,false], ['post',2,42,true], ['post',3,42,false],
      ['comment',1,46,true], ['comment',2,46,false], ['comment',2,42,true], ['comment',3,42,false], ['comment',4,42,false],
      ['user',1,42,true], ['user',2,42,false], ['user',3,42,false],
      ['group_post',1,46,true], ['group_post',2,46,false], ['group_post',2,42,true],
      ['group_post',3,42,false], ['group_post',4,42,false], ['group_post',5,42,false],
      ['group_comment',1,46,true], ['group_comment',2,46,false], ['group_comment',2,42,true],
      ['group_comment',3,42,false], ['group_comment',4,42,false]
    ];
    for (const [kind,target_id,viewer_id,expected] of cases) {
      assert.equal(Boolean(visible[kind].get({ target_id, viewer_id })), expected, `${kind} ${target_id} ${viewer_id}`);
    }
  } finally { db.close(); }
});

test('report status SQL clears resolution when reopened and sets it on the next decision', () => {
  withReports(db => {
    const update = db.prepare(sql.update);
    const read = db.prepare(sql.lock.replace(/ FOR UPDATE$/, ''));
    const key = { report_id: 13 };
    assert.equal(read.get(key).is_resolved, 1);
    assert.equal(update.run({ ...key, status: 'pending', handled_by: 56 }).changes, 1);
    assert.deepEqual({ ...read.get(key) }, { status: 'pending', handled_by: 56, is_resolved: 0 });
    assert.equal(update.run({ ...key, status: 'dismissed', handled_by: 42 }).changes, 1);
    assert.deepEqual({ ...read.get(key) }, { status: 'dismissed', handled_by: 42, is_resolved: 1 });
    assert.equal(update.run({ report_id: 99, status: 'resolved', handled_by: 42 }).changes, 0);
  });
});

test('open report lookup is scoped to the reporter and permits a new report after closure', () => {
  withReports(db => {
    const lookup = db.prepare(sql.findOpen.replace(/\s+WHERE ROWNUM = 1$/, ' LIMIT 1'));
    const binds = { target_type:'post', target_id:5, viewer_id:7 };
    assert.equal(lookup.get(binds).report_id, 11);
    assert.equal(lookup.get({...binds,viewer_id:8}), undefined);
    assert.equal(lookup.get({...binds,target_type:'group_post'}), undefined);
    assert.equal(lookup.get({target_type:'user',target_id:9,viewer_id:8}), undefined);
    db.prepare(sql.update).run({report_id:11,status:'dismissed',handled_by:42});
    assert.equal(lookup.get(binds), undefined);
  });
});

test('the report case merge escalates only active content cases with enough distinct open reporters', () => {
  withReports(db => {
    db.exec(`
      CREATE TABLE n_moderation_settings(setting_key TEXT PRIMARY KEY, setting_value TEXT);
      CREATE TABLE case_state(status TEXT);
      INSERT INTO case_state VALUES ('pending');
      INSERT INTO n_moderation_settings VALUES ('auto_hide_report_threshold','2');
      INSERT INTO n_moderation_reports VALUES
        (21,'post',5,7,'spam',NULL,NULL,'in_review','normal',NULL,'2026-11-02',NULL,NULL),
        (22,'post',5,8,'spam',NULL,NULL,'dismissed','normal',NULL,'2026-11-03',NULL,NULL),
        (23,'post',5,9,'spam',NULL,NULL,'resolved','low',NULL,'2026-11-04',NULL,NULL),
        (24,'post',5,10,'spam',NULL,NULL,'in_review','low',NULL,'2026-11-05',NULL,NULL),
        (25,'comment',5,8,'spam',NULL,NULL,'pending','low',NULL,'2026-11-05',NULL,NULL),
        (26,'comment',5,9,'spam',NULL,NULL,'pending','low',NULL,'2026-11-05',NULL,NULL);
    `);
    db.function('REGEXP_LIKE', (value, pattern, flags) => Number(value !== null && flags === 'c' && new RegExp(pattern).test(value)));
    db.function('TO_NUMBER', value => {
      assert.match(value, /^[1-9][0-9]{0,15}$/);
      return Number(value);
    });
    const source = sql.mergeCase.match(/USING \(\n([\s\S]+?)\n\) r ON/)[1];
    const updatePriority = sql.mergeCase.match(/c\.priority = (CASE[\s\S]+? END),\n/)[1];
    const insertPriority = sql.mergeCase.match(/'pending',\n  (CASE[\s\S]+? END),\n/)[1];
    const read = db.prepare(`SELECT r.report_count, r.latest_reported_at,
      ${updatePriority} AS existing_priority, ${insertPriority} AS new_priority
      FROM (${source}) r CROSS JOIN case_state c`);
    const target = { target_type: 'post', target_id: 5 };
    const setThreshold = db.prepare('UPDATE n_moderation_settings SET setting_value = ?');
    const priorities = (scope = target) => {
      const row = read.get(scope);
      return [row.existing_priority, row.new_priority];
    };
    assert.deepEqual({ ...read.get(target) }, {
      report_count: 5, latest_reported_at: '2026-11-05', existing_priority: 'high', new_priority: 'high'
    });
    assert.deepEqual(priorities({ ...target, target_type: 'comment' }), ['high', 'high']);
    for (const value of ['3', '0', '-2', '1e1', '1.5', '02', '9007199254740992', '99999999999999999', 'invalid']) {
      setThreshold.run(value);
      assert.deepEqual(priorities(), ['normal', 'normal'], value);
    }
    setThreshold.run('2');
    db.exec("UPDATE case_state SET status = 'restored'");
    assert.deepEqual(priorities(), ['normal', 'high']);
    db.exec("UPDATE case_state SET status = 'flagged'");
    assert.deepEqual(priorities(), ['high', 'high']);
    db.exec("UPDATE n_moderation_reports SET priority = 'urgent' WHERE report_id = 24");
    assert.deepEqual(priorities(), ['urgent', 'urgent']);
    db.exec("UPDATE n_moderation_reports SET target_type = 'user', priority = 'normal' WHERE target_type = 'post' AND target_id = 5");
    assert.deepEqual(priorities({ ...target, target_type: 'user' }), ['normal', 'normal']);
    db.exec('DELETE FROM n_moderation_settings');
    assert.deepEqual(priorities({ ...target, target_type: 'comment' }), ['low', 'low']);
  });
});
