import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { test } from 'node:test';

const {sql}=JSON.parse(readFileSync(new URL('../specifications/requirements/moderation-content-queue.json',import.meta.url)));
const dates=query=>query.replace(/TO_CHAR\(FROM_TZ\((\w+\.\w+), SESSIONTIMEZONE\) AT TIME ZONE 'UTC', '[^']+'\)/g,'$1');

test('content queue keeps stable totals, filters ordinary posts and ties by case ID',()=>{
  const db=new DatabaseSync(':memory:');
  try {
    db.function('fn_get_user_relationship',(viewer,user)=> viewer === user ? 'self' : 'none');
    db.exec(`
      CREATE TABLE n_moderation_cases(case_id,target_type,target_id,status,priority,assigned_to,report_count,created_at,updated_at,latest_reported_at);
      CREATE TABLE n_posts(post_id,author_id,content);
      CREATE TABLE n_users(user_id,username,avatar_url,display_name,bio,location,website,is_verified,email);
      CREATE TABLE n_user_stats(user_id,followers_count,following_count,posts_count,likes_count);
      CREATE TABLE n_post_stats(post_id,likes_count,retweets_count,replies_count);
      CREATE TABLE n_moderation_reports(report_id,target_type,target_id,reporter_user_id,reason,description,evidence_url,status,priority,handled_by,created_at,updated_at,resolved_at);
      INSERT INTO n_users VALUES (42,'reader',NULL,'Reviewer',NULL,NULL,NULL,0,'private@example.test');
      INSERT INTO n_posts VALUES (81,42,'all%'),(82,42,'all'),(83,42,'post from yesterday');
      INSERT INTO n_post_stats VALUES (81,3,1,0),(82,7,1,0);
      INSERT INTO n_moderation_cases VALUES
        (17,'post',81,'pending','high',NULL,3,'2026-11-16','2026-11-16','2026-11-16'),
        (18,'post',82,'pending','low',NULL,1,'2026-11-16','2026-11-16','2026-11-16'),
        (19,'group_post',81,'pending','high',NULL,1,'2026-11-16','2026-11-16','2026-11-16'),
        (20,'post',83,'pending','normal',NULL,0,'2026-11-15','2026-11-15','2026-11-15');
      INSERT INTO n_moderation_reports VALUES
        (10,'post',81,42,'spam',NULL,NULL,'pending','low',NULL,'2026-11-15','2026-11-16',NULL),
        (11,'post',81,42,'hate',NULL,NULL,'pending','high',NULL,'2026-11-16','2026-11-16',NULL),
        (12,'post',81,42,'spam',NULL,NULL,'pending','high',NULL,'2026-11-16','2026-11-16',NULL),
        (13,'group_post',81,42,'other',NULL,NULL,'pending','high',NULL,'2026-11-16','2026-11-16',NULL);
    `);
    const query=db.prepare(dates(sql.list).replaceAll('NVL(', 'COALESCE(')
      .replaceAll('DBMS_LOB.SUBSTR(p.content, 4000, 1)','SUBSTR(p.content, 1, 4000)')
      .replaceAll('TRUNC(SYSDATE) - 1',"'2026-11-15'")
      .replaceAll('TRUNC(SYSDATE)',"'2026-11-16'")
      .replace("SYSTIMESTAMP - INTERVAL '7' DAY","'2026-11-09'")
      .replace("SYSTIMESTAMP - INTERVAL '30' DAY","'2026-10-17'"));
    const all={post_id:null,status:'pending',priority:null,reason:null,q:null,date_range:'all',sort:'newest',viewer_id:42,start_row:1,end_row:3};
    const ids=binds=>query.all({...all,...binds}).map(row=>row.case_id);
    assert.deepEqual(ids({}),[18,17,20]);
    assert.deepEqual(ids({sort:'oldest'}),[20,17,18]);
    assert.deepEqual(ids({sort:'most_reports'}),[17,18,20]);
    assert.deepEqual(ids({sort:'most_engagement'}),[18,17,20]);
    assert.deepEqual(ids({q:'ALL%',priority:'high',reason:'spam',date_range:'week'}),[17]);
    assert.deepEqual(ids({date_range:'yesterday'}),[20]);
    assert.deepEqual(ids({post_id:82}),[18]);
    assert.deepEqual(query.all({...all,start_row:4,end_row:6}).map(row=>[row.case_id,row.total]),[[null,3]]);
    assert.equal(query.get(all).email,undefined);
    const reports=db.prepare(dates(sql.reports)).all({target_type:'post',target_id:81});
    assert.deepEqual(reports.map(row=>row.report_id),[12,11,10]);
  } finally {db.close();}
});
