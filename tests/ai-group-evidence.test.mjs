import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { test } from 'node:test';

const { query } = JSON.parse(readFileSync(new URL('../specifications/requirements/ai-group-evidence.json', import.meta.url)));
const oracleDate = /TO_(?:CHAR|TIMESTAMP)\(([^,]+), 'YYYY-MM-DD"T"HH24:MI:SS\.FF6'\)/g;
const sqliteQuery = query.replace(oracleDate, '$1')
  .replace('CAST(SYSTIMESTAMP AS TIMESTAMP)', 'current_fixture_time()')
  .replace("i.end_at - NUMTODSINTERVAL(:lookback_days, 'DAY')", 'subtract_days(i.end_at, :lookback_days)');

function fixture(t) {
  const db = new DatabaseSync(':memory:');
  t.after(() => db.close());
  db.exec(`
    CREATE TABLE dual(dummy);
    INSERT INTO dual VALUES ('X');
    CREATE TABLE n_groups(group_id INTEGER PRIMARY KEY, privacy, is_active INTEGER, is_deleted INTEGER);
    CREATE TABLE n_users(user_id INTEGER PRIMARY KEY, is_active INTEGER);
    CREATE TABLE n_group_members(group_id INTEGER, user_id INTEGER, role, status);
    CREATE TABLE n_user_blocks(user_id INTEGER, target_user_id INTEGER);
    CREATE TABLE n_group_posts(post_id INTEGER PRIMARY KEY, group_id INTEGER, author_id INTEGER, content, is_deleted INTEGER, created_at);
    CREATE TABLE n_group_comments(comment_id INTEGER PRIMARY KEY, post_id INTEGER, author_id INTEGER, content, is_deleted INTEGER, created_at);
    INSERT INTO n_groups VALUES (1,'public',1,0),(2,'private',1,0),(3,'secret',1,0),(4,'public',0,0),
      (5,'public',1,1),(6,'public',1,0),(7,'public',1,0);
    INSERT INTO n_users VALUES (10,1),(20,1),(21,1),(22,0),(23,1),(24,1),(25,1),(26,1),(27,0);
    INSERT INTO n_group_members VALUES (1,10,'admin','active'),(1,20,'member','active'),(1,21,'moderator','active'),
      (1,26,'admin','muted'),(1,27,'admin','active'),(1,25,'owner','active'),
      (2,10,'admin','active'),(3,10,'admin','active'),(4,10,'admin','active'),
      (5,10,'admin','active'),(6,20,'admin','active'),(7,10,'admin','active');
    INSERT INTO n_user_blocks VALUES (10,23),(24,10);
    INSERT INTO n_group_posts VALUES
      (1,1,20,'older public post',0,'2026-11-07T12:00:00.000000'),
      (2,1,20,'weekly report at start',0,'2026-11-10T12:00:00.000000'),
      (3,1,20,'public FAQ',0,'2026-11-16T12:00:00.000000'),
      (4,1,20,'end is exclusive',0,'2026-11-17T12:00:00.000000'),
      (5,1,20,'deleted source',1,'2026-11-16T12:00:00.000000'),
      (6,1,22,'inactive account',0,'2026-11-16T12:00:00.000000'),
      (7,1,23,'outgoing block',0,'2026-11-16T12:00:00.000000'),
      (8,1,24,'incoming block',0,'2026-11-16T12:00:00.000000'),
      (9,2,20,'private group source',0,'2026-11-16T12:00:00.000000'),
      (10,6,20,'another public group',0,'2026-11-16T12:00:00.000000');
    INSERT INTO n_group_comments VALUES
      (1,1,20,'recent comment on old post',0,'2026-11-16T12:00:00.000000'),
      (2,3,21,'public FAQ answer',0,'2026-11-16T12:00:00.000000'),
      (3,3,20,'deleted comment',1,'2026-11-16T12:00:00.000000'),
      (4,3,22,'inactive comment author',0,'2026-11-16T12:00:00.000000'),
      (5,3,24,'blocked comment author',0,'2026-11-16T12:00:00.000000'),
      (6,5,20,'comment on deleted parent',0,'2026-11-16T12:00:00.000000'),
      (7,7,20,'comment on blocked parent',0,'2026-11-16T12:00:00.000000'),
      (8,9,20,'private comment',0,'2026-11-16T12:00:00.000000');
  `);
  db.function('current_fixture_time', () => '2026-11-17T12:00:00.000000');
  db.function('subtract_days', (end, days) =>
    new Date(Date.parse(end.slice(0, 23) + 'Z') - days * 86400000).toISOString().replace('Z', '000'));
  const statement = db.prepare(sqliteQuery);
  return {
    db,
    read: (input = {}) => statement.all({
      actor_id: 10, group_id: 1, lookback_days: 7, search_term: null, match_excerpt: 0, window_end: null, ...input,
    }),
  };
}

test('group evidence rejects private scopes, missing groups and unauthorized actors', t => {
  const { read } = fixture(t);
  for (const group_id of [2, 3, 4, 5, 6, 999]) {
    assert.deepEqual(read({ group_id }), [], 'group ' + group_id);
  }
  for (const actor_id of [20, 21, 26, 27]) {
    assert.deepEqual(read({ actor_id }), [], 'actor ' + actor_id);
  }
  assert.ok(read({ actor_id: 25 }).length);
});

test('the shared query counts only visible activity and searches samples independently', t => {
  const { read } = fixture(t);
  const rows = read();
  assert.deepEqual(rows.map(row => [row.kind, row.source_id, row.post_id]), [
    ['post', 3, 3], ['comment', 2, 3], ['comment', 1, 1], ['post', 2, 2],
  ]);
  for (const row of rows) {
    assert.equal(row.window_start, '2026-11-10T12:00:00.000000');
    assert.deepEqual([row.posts_count, row.comments_count], [2, 2]);
  }
  assert.deepEqual(read({ search_term: 'FAQ' }).map(row => row.excerpt), ['public FAQ', 'public FAQ answer']);
  const [empty] = read({ search_term: 'missing' });
  assert.deepEqual([empty.kind, empty.posts_count, empty.comments_count], [null, 2, 2]);
  const [newGroup] = read({ group_id: 7 });
  assert.deepEqual([newGroup.kind, newGroup.posts_count, newGroup.comments_count], [null, 0, 0]);
  assert.equal(read({ lookback_days: 30 })[0].posts_count, 3);
});

test('examples are bounded and a fixed window still observes current access', t => {
  const { db, read } = fixture(t);
  const insert = db.prepare("INSERT INTO n_group_posts VALUES (?,1,20,?,0,'2026-11-16T12:00:00.000000')");
  for (let id = 100; id < 112; id++) insert.run(id, '资料'.repeat(210));
  const current = read();
  assert.deepEqual(current.map(row => row.source_id), [111, 110, 109, 108, 107, 106, 105, 104]);
  assert.equal(current[0].excerpt.length, 400);
  assert.equal(current[0].posts_count, 14);
  db.exec('UPDATE n_group_posts SET is_deleted=1 WHERE post_id=111');
  const window_end = current[0].window_end;
  assert.equal(read({ window_end })[0].source_id, 110);
  db.exec("UPDATE n_group_members SET role='member' WHERE group_id=1 AND user_id=10");
  assert.deepEqual(read({ window_end }), []);
  db.exec("UPDATE n_group_members SET role='admin' WHERE group_id=1 AND user_id=10; UPDATE n_groups SET privacy='private' WHERE group_id=1");
  assert.deepEqual(read({ window_end }), []);
});

test('a new filtered excerpt contains a hit beyond the prefix, and a legacy record still uses the prefix', t => {
  const { db, read } = fixture(t);
  const term = '活动报名';
  const content = '前'.repeat(398) + term + '后'.repeat(430);
  db.prepare("UPDATE n_group_posts SET content=? WHERE post_id=3").run(content);
  const legacy = read({search_term:term})[0];
  const current = read({search_term:term, match_excerpt:1, window_end:legacy.window_end})[0];
  assert.equal(legacy.excerpt, content.slice(0,400));
  assert.equal(current.excerpt, '前'.repeat(80) + term + '后'.repeat(316));
  assert.deepEqual([current.posts_count,current.comments_count,current.source_id], [2,2,3]);
  assert.equal(read({match_excerpt:1})[0].excerpt, legacy.excerpt);
});
