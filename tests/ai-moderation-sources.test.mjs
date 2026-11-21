import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { test } from 'node:test';

const {queries} = JSON.parse(readFileSync(new URL('../specifications/requirements/ai-moderation-advice.json',import.meta.url)));

test('moderation evidence reads only the requested currently public target', t => {
  const db = new DatabaseSync(':memory:');
  t.after(() => db.close());
  db.exec(`
    CREATE TABLE n_users(user_id INTEGER PRIMARY KEY,is_active INTEGER);
    CREATE TABLE n_user_blocks(user_id INTEGER,target_user_id INTEGER);
    CREATE TABLE n_posts(post_id INTEGER PRIMARY KEY,author_id INTEGER,visibility,content,is_deleted INTEGER);
    CREATE TABLE n_comments(comment_id INTEGER PRIMARY KEY,post_id INTEGER,user_id INTEGER,content,is_deleted INTEGER);
    CREATE TABLE n_groups(group_id INTEGER PRIMARY KEY,privacy,is_active INTEGER,is_deleted INTEGER);
    CREATE TABLE n_group_posts(post_id INTEGER PRIMARY KEY,group_id INTEGER,author_id INTEGER,content,is_deleted INTEGER);
    CREATE TABLE n_group_comments(comment_id INTEGER PRIMARY KEY,post_id INTEGER,author_id INTEGER,content,is_deleted INTEGER);
    INSERT INTO n_users VALUES (10,1),(11,1),(12,0),(13,1),(14,1);
    INSERT INTO n_user_blocks VALUES (10,13),(14,10);
    INSERT INTO n_posts VALUES
      (1,11,'public','public post',0),(2,11,'private','private post',0),
      (3,11,'public','deleted post',1),(4,12,'public','disabled author',0),
      (5,11,'public','invisible to viewer',0);
    INSERT INTO n_comments VALUES
      (1,1,11,'ordinary comment',0),(2,2,11,'private parent',0),
      (3,3,11,'deleted parent',0),(4,1,13,'blocked comment',0),(5,1,12,'disabled commenter',0);
    INSERT INTO n_groups VALUES (1,'public',1,0),(2,'private',1,0),(3,'secret',1,0),(4,'public',0,0);
    INSERT INTO n_group_posts VALUES
      (1,1,11,'public group post',0),(2,2,11,'private group post',0),(3,3,11,'secret group post',0),
      (4,4,11,'inactive group post',0),(5,1,13,'blocked author',0);
    INSERT INTO n_group_comments VALUES
      (1,1,11,'public group comment',0),(2,2,11,'private group comment',0),
      (3,5,11,'blocked parent',0),(4,1,14,'blocked commenter',0);
  `);
  db.function('fn_can_view_post',(actor,post)=>Number(actor===10&&post!==5));
  db.function('fn_can_view_group',(actor,group)=>Number(actor===10&&group>0));
  const statements = Object.fromEntries(Object.entries(queries).map(([key,sql]) => [
    key,db.prepare(sql.replace(/DBMS_LOB\.SUBSTR\(([^,]+),1000,1\)/g,'SUBSTR($1,1,1000)').replace(/DBMS_LOB\.GETLENGTH/g,'LENGTH')),
  ]));
  const read = (kind,id,actor=10) => statements[kind].get({target_id:id,actor_id:actor});
  for (const [kind,group,text,denied] of [
    ['post',null,'public post',[2,3,4,5,999]],
    ['comment',null,'ordinary comment',[2,3,4,5]],
    ['group_post',1,'public group post',[2,3,4,5]],
    ['group_post_comment',1,'public group comment',[2,3,4]],
  ]) {
    const row=read(kind,1);
    assert.deepEqual([row.post_id,row.group_id,row.content,row.text_length],[1,group,text,text.length]);
    for(const id of denied) assert.equal(read(kind,id),undefined,`${kind} ${id}`);
    assert.equal(read(kind,1,11),undefined);
  }
  db.exec("UPDATE n_groups SET privacy='private' WHERE group_id=1");
  assert.equal(read('group_post',1),undefined);
  assert.equal(read('group_post_comment',1),undefined);
  db.exec("UPDATE n_posts SET content = content || ' changed' WHERE post_id=1");
  assert.equal(read('post',1).content,'public post changed');
});
