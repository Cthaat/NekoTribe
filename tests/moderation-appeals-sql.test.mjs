import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { test } from 'node:test';

const {sql} = JSON.parse(readFileSync(new URL('../specifications/requirements/moderation-appeals.json',import.meta.url)));

test('moderator appeal list retains filtered totals and exposes only public applicant columns', () => {
  const db=new DatabaseSync(':memory:');
  try {
    db.function('fn_get_user_relationship', (viewer,user) => `${viewer}:${user}`);
    db.exec(`
      CREATE TABLE n_statement_appeals(appeal_id, statement_id, user_id, appeal_message, appeal_status, admin_response, created_at, updated_at);
      CREATE TABLE n_users(user_id, username, display_name, avatar_url, bio, location, website, is_verified, email, phone);
      CREATE TABLE n_user_stats(user_id, followers_count, following_count, posts_count, likes_count);
      INSERT INTO n_users VALUES (7,'member','Member',NULL,NULL,NULL,NULL,0,'private@example.test','private');
      INSERT INTO n_statement_appeals VALUES
        (11,9,7,'one','pending',NULL,'2026-01-01','2026-01-01'),
        (12,9,7,'two','pending',NULL,'2026-01-01','2026-01-01'),
        (13,10,7,'three','approved','Reviewed','2026-01-02','2026-01-02');
    `);
    const query=db.prepare(sql.list.replace(/TO_CHAR\(FROM_TZ\((a\.\w+), SESSIONTIMEZONE\) AT TIME ZONE 'UTC', '[^']+'\)/g,'$1'));
    const binds={viewer_id:42,status:'pending',start_row:1,end_row:2};
    const visible=query.all(binds);
    assert.deepEqual(visible.map(row=>row.appeal_id),[12,11]);
    assert.deepEqual(visible.map(row=>row.total),[2,2]);
    assert.equal(visible[0].email,undefined);
    assert.equal(visible[0].phone,undefined);
    assert.equal(visible[0].relation,'42:7');
    const empty=query.get({...binds,start_row:3,end_row:4});
    assert.equal(empty.appeal_id,0);
    assert.equal(empty.total,2);
    const history=query.get({...binds,status:'approved'});
    assert.equal(history.appeal_id,13);
    assert.equal(history.admin_response,'Reviewed');
  } finally { db.close(); }
});
