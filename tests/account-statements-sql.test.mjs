import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { test } from 'node:test';

const {sql} = JSON.parse(readFileSync(new URL('../specifications/requirements/account-statements.json', import.meta.url)));

test('statement pagination counts only filtered owner rows and orders ties by ID', () => {
  const db = new DatabaseSync(':memory:');
  try {
    db.exec(`
      CREATE TABLE n_account_statements(statement_id,user_id,statement_type,title,message,policy_code,status,created_at,updated_at);
      INSERT INTO n_account_statements VALUES
      (1,42,'warning','warning A','detail',NULL,'unread','2026-01-01','2026-01-01'),
      (2,42,'warning','warning B','detail',NULL,'unread','2026-01-01','2026-01-01'),
      (3,42,'warning','read warning','detail',NULL,'read','2026-01-01','2026-01-01'),
      (4,42,'info','notice','detail',NULL,'unread','2026-01-01','2026-01-01'),
      (5,77,'warning','private to another owner','detail',NULL,'unread','2026-01-01','2026-01-01');
    `);
    const statement = sql.list.replace(/TO_CHAR\(FROM_TZ\((r\.\w+), SESSIONTIMEZONE\) AT TIME ZONE 'UTC', '[^']+'\)/g, '$1');
    assert.notEqual(statement, sql.list);
    const query = db.prepare(statement);
    const owner = {user_id:42,status:'unread',statement_type:'warning',start_row:1,end_row:2};
    const rows = query.all(owner);
    assert.deepEqual(rows.map(row => row.statement_id), [2,1]);
    assert.deepEqual(rows.map(row => row.total), [2,2]);
    const empty = query.get({...owner,start_row:3,end_row:4});
    assert.equal(empty.statement_id, 0);
    assert.equal(empty.total, 2);
  } finally { db.close(); }
});
