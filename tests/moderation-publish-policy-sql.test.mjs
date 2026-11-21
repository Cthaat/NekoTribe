import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { test } from 'node:test';

const {sql} = JSON.parse(readFileSync(new URL('../specifications/requirements/moderation-publish-policy.json', import.meta.url)));

test('publishing requires an active account and denies exactly the effective mute window', () => {
  assert.match(sql.lock, /FROM n_users WHERE user_id = :user_id FOR UPDATE$/);
  const db = new DatabaseSync(':memory:');
  try {
    db.exec(`
      CREATE TABLE dual (dummy);
      INSERT INTO dual VALUES (1);
      CREATE TABLE n_users(user_id INTEGER, status TEXT, is_active INTEGER);
      CREATE TABLE n_moderation_user_restrictions(user_id INTEGER, restriction_type TEXT, status TEXT, starts_at TEXT, ends_at TEXT);
      INSERT INTO n_users VALUES
        (1,'active',1),(2,'active',1),(3,'active',1),(4,'active',1),(5,'active',1),
        (6,'active',1),(7,'suspended',0),(8,'active',0),(9,'active',1),(10,'active',1);
      INSERT INTO n_moderation_user_restrictions VALUES
        (2,'mute','active','2026-11-17 00:00:00','2026-11-17 08:00:00'),
        (3,'mute','active','2026-11-17 04:00:00','2026-11-17 08:00:00'),
        (4,'mute','active','2026-11-17 00:00:00','2026-11-17 04:00:00'),
        (5,'mute','active','2026-11-17 04:00:01',NULL),
        (6,'mute','revoked','2026-11-17 00:00:00',NULL),
        (9,'warning','active','2026-11-17 00:00:00',NULL),
        (10,'mute','active','2026-11-17 00:00:00',NULL);
    `);
    const query = db.prepare(sql.allowed.replaceAll('CURRENT_TIMESTAMP', "'2026-11-17 04:00:00'"));
    const checks = [
      [1, 1, 'unrestricted'], [2, 0, 'current'], [3, 0, 'starts now'],
      [4, 1, 'expires now'], [5, 1, 'future'], [6, 1, 'revoked'],
      [7, 0, 'suspended'], [8, 0, 'inactive'], [9, 1, 'other restriction'],
      [10, 0, 'indefinite'], [11, 0, 'missing account']
    ];
    for (const [user_id, allowed, label] of checks) {
      assert.equal(query.get({user_id}).allowed, allowed, label);
    }
  } finally {
    db.close();
  }
});
