import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { test } from 'node:test';

const {sql} = JSON.parse(readFileSync(new URL('../specifications/requirements/moderation-user-queue.json',import.meta.url)));

test('moderation user queue filters literal text, orders ties and returns a consistent total', () => {
  const db = new DatabaseSync(':memory:');
  try {
    db.exec(`
      CREATE TABLE n_users(user_id,username,display_name,avatar_url,email,status,is_active,is_verified,created_at,updated_at);
      CREATE TABLE n_user_stats(user_id,followers_count,posts_count,likes_count);
      CREATE TABLE n_posts(post_id,author_id);
      CREATE TABLE n_moderation_reports(target_type,target_id);
      CREATE TABLE n_moderation_user_restrictions(restriction_id,user_id,restriction_type,status,starts_at,ends_at);
      INSERT INTO n_users VALUES
        (1,'Reader',NULL,NULL,'one@example.test','active',1,0,'2026-01-01','2026-01-01'),
        (2,'other','Reader% staff',NULL,'two@example.test','active',1,0,'2026-01-01','2026-01-01'),
        (3,'Third',NULL,NULL,'reader2@example.test','suspended',0,0,'2026-02-01','2026-02-01');
      INSERT INTO n_posts VALUES (15,1),(16,2);
      INSERT INTO n_moderation_reports VALUES ('user',1),('post',15),('post',15),('group_post',15),('user',2);
      INSERT INTO n_moderation_user_restrictions VALUES
        (1,1,'ban','active','2020-01-01',NULL),
        (2,1,'mute','active','2020-01-01','2099-01-01'),
        (3,1,'ban','revoked','2021-01-01',NULL),
        (4,1,'ban','active','2022-01-01','2023-01-01'),
        (5,1,'ban','active','2099-01-01',NULL);
    `);
    const query = db.prepare(sql.replaceAll('NVL(', 'COALESCE(')
      .replace(/TO_CHAR\(FROM_TZ\((\w+\.\w+), SESSIONTIMEZONE\) AT TIME ZONE 'UTC', '[^']+'\)/g,'$1')
      .replaceAll('CURRENT_TIMESTAMP', "'2026-11-16'"));
    const binds={user_id:null,status:null,q:null,sort:'reports',start_row:1,end_row:3};
    const rows=query.all(binds);
    assert.deepEqual(rows.map(row=>[row.user_id,row.report_count,row.total]),[[1,3,3],[2,1,3],[3,0,3]]);
    assert.deepEqual([rows[0].active_restriction,rows[0].restriction_until],['mute','2099-01-01']);
    assert.deepEqual(query.all({...binds,sort:'oldest'}).map(x=>x.user_id),[1,2,3]);
    assert.deepEqual(query.all({...binds,sort:'newest'}).map(x=>x.user_id),[3,2,1]);
    assert.deepEqual(query.all({...binds,q:'READER%',status:'active'}).map(x=>x.user_id),[2]);
    assert.deepEqual(query.all({...binds,q:'@EXAMPLE.TEST',status:'suspended'}).map(x=>x.user_id),[3]);
    const empty=query.get({...binds,start_row:4,end_row:6});
    assert.equal(empty.user_id,null);
    assert.equal(empty.total,3);
    assert.deepEqual(query.all({...binds,user_id:3,end_row:1}).map(x=>[x.user_id,x.total]),[[3,1]]);
  } finally { db.close(); }
});
