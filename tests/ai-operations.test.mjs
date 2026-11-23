import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { test } from 'node:test';
import { compileTemplate, parse } from '@vue/compiler-sfc';

test('feedback separates model versions and insufficient ratings', () => {
  const { feedbackSql } = JSON.parse(readFileSync(new URL('../specifications/requirements/ai-operations.json', import.meta.url)));
  const db = new DatabaseSync(':memory:');
  try {
    db.exec(`
      CREATE TABLE n_ai_messages(message_id, model_id, model_version, config_revision);
      CREATE TABLE n_ai_moderation_feedback(message_id, rating);
      INSERT INTO n_ai_messages VALUES (1,'m','v1',1),(2,'m','v2',2),(3,'m','v2',2),(4,'m','v2',2);
      INSERT INTO n_ai_moderation_feedback VALUES (1,'insufficient'),(2,'helpful'),(3,'helpful'),(4,'incorrect');
    `);
    const rows = db.prepare(feedbackSql.replace(/FETCH FIRST 100 ROWS ONLY$/, 'LIMIT 100')).all();
    assert.deepEqual(rows.map(row => [row.config_revision, row.helpful, row.incorrect, row.insufficient]), [
      [2, 2, 1, 0], [1, 0, 0, 1]
    ]);
  } finally {
    db.close();
  }
});

test('the moderator view renders feedback distribution and sync status', () => {
  const name = 'app/pages/moderation/ai.vue';
  const source = readFileSync(new URL('../' + name, import.meta.url), 'utf8');
  const compiled = compileTemplate({ source: parse(source).descriptor.template.content, filename: name, id: 'ai-ops' });
  assert.deepEqual(compiled.errors, []);
  assert.match(compiled.code, /ratingPercent/);
  assert.match(compiled.code, /last_success_at/);
});
