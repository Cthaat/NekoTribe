import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {DatabaseSync} from 'node:sqlite';
import {test} from 'node:test';

const statements = JSON.parse(readFileSync(new URL('../specifications/requirements/user-visibility-sql.json', import.meta.url)));

test('visibility pages share one scoped count, hide expired mutes and order ties by ID', () => {
  const db = new DatabaseSync(':memory:');
  try {
    db.function('fn_get_user_relationship', (viewer, user) => `${viewer}:${user}`);
    db.exec(`
      CREATE TABLE v_user_profile_public(user_id, username, avatar_url, display_name, bio, location, website,
        is_verified, followers_count, following_count, posts_count, likes_count, created_at, is_active);
      CREATE TABLE n_user_blocks(user_id, target_user_id);
      CREATE TABLE n_user_mutes(user_id, target_user_id, expires_at);
      INSERT INTO v_user_profile_public VALUES
        (3,'c',NULL,NULL,NULL,NULL,NULL,0,10,0,0,0,'2030-01-01',1),
        (2,'b',NULL,NULL,NULL,NULL,NULL,0,10,0,0,0,'2030-01-01',1),
        (4,'d',NULL,NULL,NULL,NULL,NULL,0,20,0,0,0,'2030-01-01',1),
        (5,'e',NULL,NULL,NULL,NULL,NULL,0,30,0,0,0,'2030-01-01',0),
        (6,'f',NULL,NULL,NULL,NULL,NULL,0,40,0,0,0,'2030-01-01',1);
      INSERT INTO n_user_blocks VALUES (42,3),(42,2),(42,5),(10,6);
      INSERT INTO n_user_mutes VALUES (42,3,NULL),(42,2,'2099-01-01Z'),(42,4,'2000-01-01Z'),(42,5,NULL),(10,6,NULL);
    `);
    const oracleTimestamp = `TO_CHAR(FROM_TZ(rel.expires_at, SESSIONTIMEZONE) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"')`;
    assert.ok(statements.mutes.includes(oracleTimestamp));
    for (const statement of [statements.blocks, statements.mutes.replace(oracleTimestamp, 'rel.expires_at')]) {
      const list = db.prepare(statement);
      const page = list.all({viewer_id:42,start_row:1,end_row:2});
      assert.deepEqual(page.map(row => row.user_id), [2,3]);
      assert.deepEqual(page.map(row => row.total), [2,2]);
      assert.deepEqual(page.map(row => row.relation), ['42:2','42:3']);
      const outside = list.all({viewer_id:42,start_row:3,end_row:4});
      assert.equal(outside.length,1);
      assert.equal(outside[0].user_id,0);
      assert.equal(outside[0].total,2);
    }
  } finally { db.close(); }
});

test('follow pages filter both directions of a block and keep common following scoped to the viewer', () => {
  const db = new DatabaseSync(':memory:');
  try {
    db.function('fn_get_user_relationship', (_viewer, _user) => 'none');
    db.exec(`
      CREATE TABLE v_user_profile_public(user_id, username, avatar_url, display_name, bio, location, website,
        is_verified, followers_count, following_count, posts_count, likes_count, created_at, is_active);
      CREATE TABLE n_users(user_id, is_active);
      CREATE TABLE n_user_blocks(user_id, target_user_id);
      CREATE TABLE n_user_follows(follower_id, following_id, status);
      INSERT INTO n_users VALUES(9,1),(42,1);
      INSERT INTO v_user_profile_public VALUES
        (1,'a',NULL,NULL,NULL,NULL,NULL,0,10,0,0,0,'2030-01-01',1),
        (2,'b',NULL,NULL,NULL,NULL,NULL,0,10,0,0,0,'2030-01-01',1),
        (3,'c',NULL,NULL,NULL,NULL,NULL,0,10,0,0,0,'2030-01-01',1),
        (4,'d',NULL,NULL,NULL,NULL,NULL,0,10,0,0,0,'2030-01-01',1);
      INSERT INTO n_user_follows VALUES (9,1,'active'),(9,2,'active'),(9,3,'active'),(9,4,'active'),
        (42,1,'active'),(42,2,'active'),(42,3,'cancelled'),(1,9,'active'),(2,9,'active');
      INSERT INTO n_user_blocks VALUES(2,42),(9,4);
    `);
    const binds = {viewer_id:42,target_id:9,start_row:1,end_row:20};
    const read = kind => db.prepare(statements[kind]).all(binds).map(row => row.user_id);
    assert.deepEqual(read('followers'),[1]);
    assert.deepEqual(read('following'),[1,3]);
    assert.deepEqual(read('mutual-following'),[1]);
    db.exec('INSERT INTO n_user_blocks VALUES(9,42)');
    for (const kind of ['followers','following','mutual-following']) {
      const result = db.prepare(statements[kind]).all(binds);
      assert.equal(result.length,1);
      assert.equal(result[0].user_id,0);
      assert.equal(result[0].total,0);
    }
  } finally { db.close(); }
});
