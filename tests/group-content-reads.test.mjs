import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';

const read = path => readFileSync(new URL(path, import.meta.url), 'utf8');
const nuxt = read('../server/services/v2/groups.ts');
const goPath = '../../go/internal/server/group_content.go';
const rustPath = '../../rust/src/group_content.rs';
const posts = nuxt.match(/const groupContentPostsSql = `([\s\S]+?)`;/)[1];
const comments = nuxt.match(/const groupContentCommentsSql = `([\s\S]+?)`;/)[1];

test('each backend ships the same group-content read queries with the Go driver wrapper', {
  skip: ![goPath, rustPath].every(path => existsSync(new URL(path, import.meta.url)))
}, () => {
  const go = read(goPath);
  const rust = read(rustPath);
  const goPosts = go.match(/const groupContentPostsSQL = `([\s\S]+?)`/)[1];
  // go-oracledb classifies this read by its leading SELECT keyword.
  const outerSelect = 'SELECT group_allowed,total,post_id,group_id,author_id,content,media_urls,\n' +
    '  is_pinned,is_announcement,likes_count,comments_count,views_count,created_at,updated_at,is_liked_by_me';
  const innerSelect = posts.replace('r.updated_at,r.is_liked_by_me\n', 'r.updated_at,r.is_liked_by_me,r.rn\n')
    .replace(/\nORDER BY r\.rn$/, '');
  assert.equal(goPosts, `${outerSelect}\nFROM (\n${innerSelect}\n) ORDER BY rn`);
  assert.equal(go.match(/const groupContentCommentsSQL = `([\s\S]+?)`/)[1], comments);
  assert.equal(rust.match(/const POSTS: &str = "([\s\S]+?)";/)[1], posts);
  assert.equal(rust.match(/const COMMENTS: &str = "([\s\S]+?)";/)[1], comments);
});

test('group comment writes use the same active-author and bidirectional block query', t => {
  const sql = nuxt.match(/const groupAuthorVisibleSql = `([\s\S]+?)`;/)[1];
  const sources = [
    ['../../go/internal/server/group_post_write.go', /const groupAuthorVisibleSQL = `([\s\S]+?)`/],
    ['../../rust/src/group_post_write.rs', /const AUTHOR_VISIBLE: &str = "([\s\S]+?)";/]
  ];
  for (const [path, pattern] of sources) {
    if (existsSync(new URL(path, import.meta.url))) assert.equal(read(path).match(pattern)[1], sql);
  }
  const db = new DatabaseSync(':memory:');
  t.after(() => db.close());
  db.exec(`
    CREATE TABLE n_users (user_id, is_active);
    CREATE TABLE n_user_blocks (user_id, target_user_id);
    INSERT INTO n_users VALUES (21,1),(22,0),(23,1),(24,1);
    INSERT INTO n_user_blocks VALUES (42,23),(24,42);
  `);
  const query = db.prepare(sql);
  assert.equal(query.get({viewer_id:42, author_id:21}).visible,1);
  for (const author_id of [22,23,24,999]) assert.equal(query.get({viewer_id:42,author_id}),undefined);
});

test('group content snapshot scopes ancestors, total, tie order and viewer flags', t => {
  const db = new DatabaseSync(':memory:');
  t.after(() => db.close());
  db.exec(`
    CREATE TABLE n_groups (group_id, is_active, is_deleted, privacy);
    CREATE TABLE n_users (user_id, is_active);
    CREATE TABLE n_user_blocks (user_id, target_user_id);
    CREATE TABLE n_group_posts (post_id, group_id, author_id, content, media_urls,
      is_pinned, is_announcement, likes_count, comments_count, views_count, created_at, updated_at, is_deleted);
    CREATE TABLE n_group_comments (comment_id, post_id, author_id, parent_comment_id,
      reply_to_user_id, content, likes_count, created_at, updated_at, is_deleted);
    CREATE TABLE n_group_post_likes (post_id, user_id);
    CREATE TABLE n_group_comment_likes (comment_id, user_id);
    CREATE TABLE n_group_members (group_id, user_id, status, role);
    INSERT INTO n_groups VALUES (7,1,0,'public'),(8,0,1,'public'),(9,1,0,'private'),(10,1,0,'public');
    INSERT INTO n_users VALUES (21,1),(42,1),(43,0),(44,1),(45,1);
    INSERT INTO n_user_blocks VALUES (42,44),(45,42);
    INSERT INTO n_group_posts VALUES
      (1,7,21,'pinned',NULL,1,0,0,0,0,'2026-10-01',NULL,0),
      (2,7,21,'announcement',NULL,0,1,0,0,0,'2026-11-01',NULL,0),
      (3,7,42,'first tie',NULL,0,0,0,0,0,'2026-11-03',NULL,0),
      (4,7,21,'second tie',NULL,0,0,1,3,0,'2026-11-03',NULL,0),
      (5,7,21,'deleted',NULL,1,1,0,0,0,'2026-11-03',NULL,1),
      (6,8,21,'dissolved group',NULL,0,0,0,0,0,'2026-11-03',NULL,0),
      (7,9,21,'private group',NULL,0,0,0,0,0,'2026-11-03',NULL,0);
    INSERT INTO n_group_comments VALUES
      (1,4,21,NULL,NULL,'comment',2,'2026-11-03',NULL,0),
      (2,4,42,1,21,'reply',1,'2026-11-03',NULL,0),
      (3,4,42,NULL,NULL,'removed',0,'2026-11-03',NULL,1),
      (4,5,42,NULL,NULL,'deleted post',0,'2026-11-03',NULL,0),
      (5,4,43,NULL,NULL,'inactive author',0,'2026-11-03',NULL,0),
      (6,4,44,NULL,NULL,'outgoing block',0,'2026-11-03',NULL,0),
      (7,4,45,NULL,NULL,'incoming block',0,'2026-11-03',NULL,0);
    INSERT INTO n_group_post_likes VALUES (4,42);
    INSERT INTO n_group_comment_likes VALUES (2,21);
    INSERT INTO n_group_members VALUES (7,42,'active','moderator'),(7,20,'muted','admin'),
      (9,42,'active','member'),(9,20,'pending','member');
  `);
  const list = db.prepare(posts);
  const replies = db.prepare(comments);
  const scope = { viewer_id: 42, group_id: 7, post_id: 0, start_row: 1, end_row: 10 };
  const args = { ...scope, post_type: 'all' };
  assert.deepEqual(list.all(args).map(row => row.post_id), [1, 2, 4, 3]);
  const [detail] = list.all({ ...args, post_id: 4 });
  assert.equal(detail.is_liked_by_me, 1);
  const [emptyPage] = list.all({ ...args, start_row: 9, end_row: 12 });
  assert.equal(emptyPage.total, 4);
  assert.equal(emptyPage.post_id, null);
  assert.equal(list.get({ ...args, group_id: 10 }).total, 0);
  assert.equal(list.get({ ...args, group_id: 8 }).group_allowed, 0);
  assert.equal(list.get({ ...args, group_id: 9, viewer_id: 21 }).group_allowed, 0);
  assert.equal(list.get({ ...args, group_id: 9, viewer_id: 20 }).group_allowed, 0);
  assert.equal(list.get({ ...args, group_id: 9 }).post_id, 7);
  assert.equal(list.get({ ...args, post_id: 7 }).post_id, null);
  const [pinned] = list.all({ ...args, post_type: 'pinned' });
  assert.equal(pinned.post_id, 1);
  assert.equal(pinned.total, 1);
  const c = { ...scope, post_id: 4, comment_sort: 'newest', target_comment_id: 0 };
  assert.deepEqual(replies.all(c).map(row => row.comment_id), [2, 1]);
  assert.deepEqual(replies.all({ ...c, comment_sort: 'oldest' }).map(row => row.comment_id), [1, 2]);
  assert.deepEqual(replies.all({ ...c, comment_sort: 'popular' }).map(row => row.comment_id), [1, 2]);
  assert.deepEqual(replies.all(c).map(row => row.can_delete_by_me), [1, 1]);
  assert.equal(replies.get({ ...c, viewer_id: 21, target_comment_id: 2 }).is_liked_by_me, 1);
  assert.equal(replies.get({ ...c, viewer_id: 20, target_comment_id: 1 }).can_delete_by_me, 0);
  assert.equal(replies.get({ ...c, post_id: 5 }).post_allowed, 0);
  assert.equal(replies.get({ ...c, group_id: 9 }).post_allowed, 0);
  const selected = replies.get({ ...c, target_comment_id: 1, end_row: 1 });
  assert.deepEqual([selected.comment_id, selected.post_id, selected.total], [1,4,1]);
  for (const target of [3,4,5,6,7,999]) {
    const result = replies.get({ ...c, target_comment_id: target, end_row: 1 });
    assert.deepEqual([result.comment_id, result.total], [null,0]);
  }
  db.exec('UPDATE n_group_comments SET reply_to_user_id=44 WHERE comment_id=2');
  const hiddenReply = replies.get({ ...c, target_comment_id: 2, end_row: 1 });
  assert.deepEqual([hiddenReply.comment_id, hiddenReply.reply_to_user_id], [2,null]);
  db.exec('INSERT INTO n_user_blocks VALUES (21,42)');
  assert.equal(replies.get(c).post_allowed, 0);
  assert.equal(list.get({ ...args, post_id: 4 }).post_id, null);
});

test('group comment notices require current ancestry and recipient preference', t => {
  const sql = nuxt.match(/const groupCommentRecipientsSql = `([\s\S]+?)`;/)[1];
  const goPath = '../../go/internal/server/group_comment_write.go';
  const rustPath = '../../rust/src/group_comment_write.rs';
  if ([goPath, rustPath].every(path => existsSync(new URL(path, import.meta.url)))) {
    assert.equal(read(goPath).match(/const groupCommentRecipientsSQL = `([\s\S]+?)`/)[1], sql);
    assert.equal(read(rustPath).match(/const RECIPIENTS:\s*&str\s*=\s*"([\s\S]+?)";/)[1], sql);
  }
  const db = new DatabaseSync(':memory:');
  t.after(() => db.close());
  db.exec(`
    CREATE TABLE n_groups(group_id,is_active,is_deleted,name,privacy);
    CREATE TABLE n_group_posts(post_id,group_id,author_id,is_deleted);
    CREATE TABLE n_group_comments(comment_id,post_id,author_id,parent_comment_id,is_deleted);
    CREATE TABLE n_users(user_id,display_name,username,is_active);
    CREATE TABLE n_user_blocks(user_id,target_user_id);
    CREATE TABLE n_group_members(group_id,user_id,status);
    CREATE TABLE n_group_notification_preferences(group_id,user_id,is_enabled);
    INSERT INTO n_groups VALUES (7,1,0,'Group','private');
    INSERT INTO n_group_posts VALUES (2,7,20,0),(3,7,21,0);
    INSERT INTO n_group_comments VALUES (4,2,21,NULL,0),(5,2,42,4,0),(6,3,22,NULL,0);
    INSERT INTO n_users VALUES (42,'Member','member',1),(20,NULL,'post-author',1),(21,NULL,'parent-author',1);
    INSERT INTO n_group_members VALUES (7,20,'active'),(7,21,'pending');
  `);
  const recipients = db.prepare(sql.replaceAll('NVL(', 'COALESCE('));
  const input = { group_id: 7, post_id: 2, comment_id: 5, actor_id: 42 };
  const ids = args => recipients.all({ ...input, ...args }).map(row => row.user_id);
  assert.deepEqual(ids({}), [20]);
  assert.deepEqual(ids({ group_id: 8 }), []);
  assert.deepEqual(ids({ post_id: 3 }), []);
  assert.deepEqual(ids({ actor_id: 20 }), []);
  db.exec("UPDATE n_group_members SET status='active';");
  assert.deepEqual(ids({}), [20, 21]);
  db.exec('INSERT INTO n_user_blocks VALUES (20,42),(42,21);');
  assert.deepEqual(ids({}), []);
  db.exec('DELETE FROM n_user_blocks; INSERT INTO n_user_blocks VALUES (21,20);');
  assert.deepEqual(ids({}), [20]);
  db.exec('DELETE FROM n_user_blocks; UPDATE n_users SET is_active=0 WHERE user_id=20;');
  assert.deepEqual(ids({}), []);
  db.exec('UPDATE n_users SET is_active=1 WHERE user_id=20;');
  db.exec('INSERT INTO n_group_notification_preferences VALUES (7,20,0);');
  assert.deepEqual(ids({}), [21]);
  db.exec('DELETE FROM n_group_notification_preferences; UPDATE n_group_comments SET author_id=20 WHERE comment_id=4;');
  assert.deepEqual(ids({}), [20]);
  db.exec('UPDATE n_group_comments SET parent_comment_id=6 WHERE comment_id=5;');
  assert.deepEqual(ids({}), [20]);
  db.exec('UPDATE n_groups SET is_active=0;');
  assert.deepEqual(ids({}), []);
});

test('group post notices share ownership, active-member and bidirectional block filters', t => {
  const sql = nuxt.match(/const groupPostRecipientsSql = `([\s\S]+?)`;/)[1];
  const sources = [
    ['../../go/internal/server/group_post_write.go', /const groupPostRecipientsSQL = `([\s\S]+?)`/],
    ['../../rust/src/group_post_write.rs', /const RECIPIENTS: &str = "([\s\S]+?)";/]
  ];
  for (const [path, pattern] of sources) {
    if (existsSync(new URL(path, import.meta.url))) assert.equal(read(path).match(pattern)[1],sql);
  }
  const db = new DatabaseSync(':memory:');
  t.after(() => db.close());
  db.exec(`
    CREATE TABLE n_groups(group_id,is_active,is_deleted,name);
    CREATE TABLE n_group_posts(post_id,group_id,author_id,is_deleted);
    CREATE TABLE n_users(user_id,display_name,username,is_active);
    CREATE TABLE n_group_members(group_id,user_id,status);
    CREATE TABLE n_group_notification_preferences(group_id,user_id,is_enabled);
    CREATE TABLE n_user_blocks(user_id,target_user_id);
    INSERT INTO n_groups VALUES (7,1,0,'Group'),(8,1,0,'Other');
    INSERT INTO n_group_posts VALUES (2,7,42,0),(3,8,42,0),(4,7,20,0);
    INSERT INTO n_users VALUES
      (42,'Member','member',1),(20,NULL,'visible',1),(21,NULL,'inactive',0),
      (22,NULL,'muted',1),(23,NULL,'blocker',1),(24,NULL,'blocked',1),
      (25,NULL,'no-notify',1);
    INSERT INTO n_group_members VALUES
      (7,42,'active'),(7,20,'active'),(7,21,'active'),(7,22,'muted'),
      (7,23,'active'),(7,24,'active'),(7,25,'active');
    INSERT INTO n_user_blocks VALUES (23,42),(42,24);
    INSERT INTO n_group_notification_preferences VALUES (7,25,0);
  `);
  const recipients=db.prepare(sql.replaceAll('NVL(', 'COALESCE('));
  const ids=(post_id=2)=>recipients.all({group_id:7,actor_id:42,post_id}).map(row=>row.user_id);
  assert.deepEqual(ids(),[20]);
  assert.deepEqual(ids(3),[]);
  assert.deepEqual(ids(4),[]);
  db.exec('UPDATE n_users SET is_active=0 WHERE user_id=42');
  assert.deepEqual(ids(),[]);
});
