import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { test } from 'node:test';

const {sql} = JSON.parse(readFileSync(new URL('../specifications/requirements/moderation-ban-expiry.json', import.meta.url)));
const scenarios = JSON.parse(readFileSync(new URL('../specifications/scenarios/moderation-ban-expiry.json', import.meta.url)));

for (const scenario of scenarios.cases) {
  test(`timed ban recovery: ${scenario.id}`, () => {
    const db = new DatabaseSync(':memory:');
    try {
      db.exec(`
        CREATE TABLE n_users(user_id INTEGER PRIMARY KEY,status TEXT,is_active INTEGER,updated_at TEXT);
        CREATE TABLE n_auth_sessions(user_id INTEGER,revoked_at TEXT);
        CREATE TABLE n_moderation_user_restrictions(user_id INTEGER,restriction_type TEXT,status TEXT,starts_at TEXT,ends_at TEXT);
        INSERT INTO n_auth_sessions VALUES (42,'2026-11-17 07:00:00');
        INSERT INTO n_users VALUES (43,'suspended',0,NULL);
        INSERT INTO n_moderation_user_restrictions VALUES (43,'ban','active','2026-11-17 07:00:00','2026-11-17 08:00:00');
      `);
      db.prepare('INSERT INTO n_users VALUES (42,?,?,NULL)').run(scenario.account, scenario.active);
      const add = db.prepare('INSERT INTO n_moderation_user_restrictions VALUES (42,?,?,?,?)');
      for (const record of scenario.restrictions) add.run(...record);
      const prepare = statement => db.prepare(statement.replaceAll('CURRENT_TIMESTAMP', `'${scenarios.now}'`));
      const restore = prepare(sql.restore);
      const expire = prepare(sql.expire);
      const candidates = prepare(sql.candidates.replace('FETCH FIRST 100 ROWS ONLY', 'LIMIT 100'));
      const key = {user_id: 42};
      const attempt = () => {
        db.exec('BEGIN');
        const restored = restore.run(key).changes;
        const expired = restored ? expire.run(key).changes : 0;
        db.exec('COMMIT');
        return [restored, expired];
      };
      assert.deepEqual(candidates.all().map(row => row.user_id), scenario.restored ? [42, 43] : [43]);
      assert.deepEqual(attempt(), [Number(scenario.restored), scenario.expired]);
      assert.deepEqual(attempt(), [0, 0], 'repeat attempt has no effect');
      assert.deepEqual(candidates.all().map(row => row.user_id), [43]);
      const record = db.prepare('SELECT status,is_active FROM n_users WHERE user_id=42').get();
      assert.equal(record.status, scenario.restored ? 'active' : scenario.account);
      assert.equal(record.is_active, scenario.restored ? 1 : scenario.active);
      assert.equal(db.prepare('SELECT revoked_at FROM n_auth_sessions WHERE user_id=42').get().revoked_at, '2026-11-17 07:00:00');
      assert.equal(db.prepare('SELECT status FROM n_users WHERE user_id=43').get().status, 'suspended');
      assert.equal(db.prepare("SELECT COUNT(*) AS n FROM n_moderation_user_restrictions WHERE restriction_type='mute' AND status='expired'").get().n, 0);
    } finally { db.close(); }
  });
}
