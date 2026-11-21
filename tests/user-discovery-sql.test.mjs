import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { test } from 'node:test';

const sql = JSON.parse(readFileSync(new URL('../specifications/requirements/user-discovery-sql.json', import.meta.url)));

test('discovery ranks matching public profiles, scopes recommendations and preserves empty page totals', () => {
  const db = new DatabaseSync(':memory:');
  try {
    db.function('fn_get_user_relationship', (viewer, id) => `${viewer}:${id}`);
    db.exec(`
      CREATE TABLE v_user_profile_public(user_id, username, avatar_url, display_name, bio, location, website,
        is_verified, followers_count, following_count, posts_count, likes_count, created_at, is_active);
      CREATE TABLE n_user_blocks(user_id, target_user_id);
      CREATE TABLE n_user_follows(follower_id, following_id, status);
      INSERT INTO v_user_profile_public VALUES
        (42,'self',NULL,NULL,NULL,NULL,NULL,0,100,0,0,0,'2030-01-01',1),
        (4,'d',NULL,NULL,'Found in BIO',NULL,NULL,1,1,0,3,0,'2030-01-02',1),
        (3,'c',NULL,'Found in name',NULL,NULL,NULL,1,1,0,3,0,'2030-01-02',1),
        (2,'found_username',NULL,NULL,NULL,NULL,NULL,0,5,0,0,0,'2030-01-01',1),
        (5,'found_inactive',NULL,NULL,NULL,NULL,NULL,1,50,0,0,0,'2030-01-03',0),
        (6,'blocked',NULL,NULL,NULL,NULL,NULL,0,50,0,0,0,'2030-01-01',1),
        (7,'blocking',NULL,NULL,NULL,NULL,NULL,0,50,0,0,0,'2030-01-01',1);
      INSERT INTO n_user_follows VALUES (42,2,'active'), (42,4,'cancelled'), (3,42,'active');
      INSERT INTO n_user_blocks VALUES (42,6),(7,42);
    `);
    const search = db.prepare(sql.search);
    const params = { viewer_id:42, pattern:'%found%', verified_only:0, sort_mode:'popular', start_row:1, end_row:20 };
    assert.deepEqual(search.all(params).map(row => row.user_id), [2,3,4]);
    assert.deepEqual(search.all({...params, sort_mode:'newest'}).map(row => row.user_id), [3,4,2]);
    assert.deepEqual(search.all({...params, sort_mode:'oldest'}).map(row => row.user_id), [2,3,4]);
    assert.deepEqual(search.all({...params, verified_only:1}).map(row => row.user_id), [3,4]);
    const empty = search.get({...params, start_row:21, end_row:40});
    assert.equal(empty.user_id, 0);
    assert.equal(empty.total, 3);

    assert.match(sql.recommendations, /FETCH FIRST :row_limit ROWS ONLY$/);
    const recommend = db.prepare(sql.recommendations.replace(/FETCH FIRST :row_limit ROWS ONLY$/, 'LIMIT :row_limit'));
    assert.deepEqual(recommend.all({ viewer_id:42, row_limit:50 }).map(row => row.user_id), [3,4]);
    db.exec('DELETE FROM n_user_blocks WHERE user_id = 42 AND target_user_id = 6');
    assert.deepEqual(recommend.all({ viewer_id:42, row_limit:1 }).map(row => row.user_id), [6]);
  } finally {
    db.close();
  }
});
