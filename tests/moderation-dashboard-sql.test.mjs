import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { test } from 'node:test';
import { moderationSettings } from '../server/database/schema-definition.mjs';

const contract = JSON.parse(readFileSync(new URL('../specifications/requirements/moderation-dashboard.json', import.meta.url)));
test('dashboard edit registry matches the moderation seeds', () => {
  assert.deepEqual(contract.settings,Object.fromEntries(moderationSettings.map(s => [s.key,s.value_type])));
});

test('dashboard counts distinguish open reports and completed appeals at each denominator', () => {
  const db = new DatabaseSync(':memory:');
  try {
    db.exec(`
      CREATE TABLE dual(dummy);
      INSERT INTO dual VALUES (1);
      CREATE TABLE n_moderation_cases(status,created_at,resolved_at);
      CREATE TABLE n_moderation_actions(action,created_at);
      CREATE TABLE n_moderation_reports(status);
      CREATE TABLE n_statement_appeals(appeal_status);
    `);
    const query = db.prepare(contract.sql.stats
      .replaceAll('NVL(', 'COALESCE(')
      .replace('TRUNC(SYSDATE)', "'2026-11-16'")
      .replace(/CAST\((\w+) AS DATE\)/g,'julianday($1)')
      .replace('* 100','* 100.0'));
    assert.deepEqual({...query.get()},{pending:0,approved:0,rejected:0,flagged:0,today_processed:0,avg_process_minutes:0,open_reports:0,appeal_success_rate:0});
    db.exec(`
      INSERT INTO n_moderation_cases VALUES
        ('pending','2026-11-16T00:00:00',NULL),
        ('approved','2026-11-16T00:00:00','2026-11-16T00:15:00'),
        ('rejected','2026-11-16T00:00:00','2026-11-16T00:45:00'),
        ('flagged','2026-11-16T00:00:00',NULL);
      INSERT INTO n_moderation_actions VALUES
        ('approve','2026-11-16'),('mute','2026-11-16'),('reject','2026-11-15'),('appeal_approved','2026-11-16');
      INSERT INTO n_moderation_reports VALUES ('pending'),('in_review'),('resolved'),('dismissed');
      INSERT INTO n_statement_appeals VALUES ('approved'),('approved'),('rejected'),('pending');
    `);
    assert.deepEqual({...query.get()},{pending:1,approved:1,rejected:1,flagged:1,today_processed:2,avg_process_minutes:30,open_reports:2,appeal_success_rate:67});
  } finally { db.close(); }
});
