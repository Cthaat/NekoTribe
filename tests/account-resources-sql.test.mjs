import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { test } from 'node:test';

const { sql } = JSON.parse(readFileSync(new URL('../specifications/requirements/account-resources.json', import.meta.url)));

test('usage totals only the current account ready media and conversations', () => {
  const db = new DatabaseSync(':memory:');
  try {
    db.exec(`
      CREATE TABLE dual(dummy);
      INSERT INTO dual VALUES (1);
      CREATE TABLE n_media_assets(owner_user_id, status, file_size);
      INSERT INTO n_media_assets VALUES (42,'ready',256),(42,'ready',512),(42,'pending',1024),(77,'ready',2048);
      CREATE TABLE n_ai_conversations(owner_user_id);
      INSERT INTO n_ai_conversations VALUES (42),(42),(77);
    `);
    const result = db.prepare(sql.usage).get({ user_id: 42 });
    assert.deepEqual({ ...result }, { files: 2, bytes: 768, conversations: 2 });
  } finally {
    db.close();
  }
});

test('export excludes deleted posts and other users private bookmarks', () => {
  const db = new DatabaseSync(':memory:');
  try {
    db.exec(`
      CREATE TABLE n_posts(post_id, author_id, is_deleted, content, created_at);
      INSERT INTO n_posts VALUES
        (1,42,0,'own content','2026-11-21'),
        (2,42,1,'deleted','2026-11-21'),
        (3,77,0,'other account private content','2026-11-21'),
        (4,77,0,'public but not copied','2026-11-21'),
        (5,77,0,'other account bookmark','2026-11-21');
      CREATE TABLE n_post_bookmarks(post_id, user_id, created_at);
      INSERT INTO n_post_bookmarks VALUES
        (2,42,'2026-11-21'),(3,42,'2026-11-21'),(4,42,'2026-11-21'),(5,77,'2026-11-21');
    `);
    db.function('fn_can_view_post', (actor, post) => Number(actor === 42 && post !== 3));
    const statement = query => db.prepare(query.replace(
      /TO_CHAR\(FROM_TZ\(([pb]\.created_at), SESSIONTIMEZONE\) AT TIME ZONE 'UTC', '[^']+'\)/g, '$1'
    ));
    assert.deepEqual(statement(sql.posts).all({ user_id: 42 }).map(row => ({ ...row })), [
      { post_id: 1, content: 'own content', created_at: '2026-11-21' }
    ]);
    assert.deepEqual(statement(sql.bookmarks).all({ user_id: 42 }).map(row => ({ ...row })), [
      { post_id: 4, created_at: '2026-11-21' }
    ]);
  } finally {
    db.close();
  }
});
