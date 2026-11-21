import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { test } from 'node:test';
import { schemaFeatures } from '../server/database/schema-definition.mjs';
import { summarizeModerationFeedback } from '../scripts/ai-moderation-feedback-report.mjs';

const contract = JSON.parse(readFileSync(new URL('../specifications/requirements/ai-moderation-feedback.json', import.meta.url)));
const feedbackSchema = schemaFeatures.find(feature => feature.id === 'ai-moderation-feedback').steps[0];

test('the shared aggregate groups ratings by original model and excludes unrelated messages', t => {
  const db = new DatabaseSync(':memory:');
  t.after(() => db.close());
  db.exec(`
    PRAGMA foreign_keys = ON;
    CREATE TABLE n_ai_conversations (conversation_id TEXT PRIMARY KEY, purpose TEXT);
    CREATE TABLE n_ai_messages (
      message_id TEXT PRIMARY KEY, model_id TEXT, model_version TEXT, config_revision INTEGER,
      conversation_id TEXT REFERENCES n_ai_conversations ON DELETE CASCADE, role TEXT, content TEXT
    );
    ${feedbackSchema.sql};
    INSERT INTO n_ai_conversations VALUES ('mod', 'moderation'), ('writing', 'writing');
    INSERT INTO n_ai_messages VALUES
      ('a','local',NULL,4,'mod','assistant','private body'),
      ('b','local',NULL,4,'mod','assistant','private body'),
      ('c','local',NULL,4,'mod','assistant','private body'),
      ('d','local','2.1',5,'mod','assistant','private body'),
      ('e','local',NULL,4,'writing','assistant','private body'),
      ('f','local',NULL,4,'mod','user','private body'),
      ('g',NULL,NULL,4,'mod','assistant','private body'),
      ('h','local',NULL,NULL,'mod','assistant','private body'),
      ('unrated','local',NULL,4,'mod','assistant','private body');
    INSERT INTO n_ai_moderation_feedback(message_id,rating) VALUES
      ('a','helpful'),('b','helpful'),('c','incorrect'),('d','insufficient'),
      ('e','helpful'),('f','helpful'),('g','helpful'),('h','helpful');
  `);
  const query = db.prepare(contract.queries.aggregate);
  const report = summarizeModerationFeedback(query.all());
  assert.deepEqual(report.groups, [
    {model_id:'local', model_version:null, config_revision:4,
      ratings:{helpful:2, incorrect:1, insufficient:0}, sample_size:3, helpful_rate:2/3},
    {model_id:'local', model_version:'2.1', config_revision:5,
      ratings:{helpful:0, incorrect:0, insufficient:1}, sample_size:1, helpful_rate:0},
  ]);
  assert.doesNotMatch(JSON.stringify(report), /private body|message_id|conversation_id/);
  assert.throws(() => db.prepare('UPDATE n_ai_moderation_feedback SET rating = ? WHERE message_id = ?').run('approved', 'a'));
  assert.throws(() => db.prepare('INSERT INTO n_ai_moderation_feedback(message_id,rating) VALUES (?,?)').run('a','incorrect'));
  db.exec("DELETE FROM n_ai_conversations WHERE conversation_id = 'mod'");
  assert.equal(db.prepare('SELECT COUNT(*) AS remaining FROM n_ai_moderation_feedback').get().remaining, 1);
  assert.deepEqual(summarizeModerationFeedback(query.all()).groups, []);
});

test('the report rejects duplicate counts, overflow and rows containing message content', () => {
  const row = {model_id:'local', model_version:null, config_revision:1, rating:'helpful', count:2};
  assert.throws(() => summarizeModerationFeedback([row,row]), /Duplicate/);
  assert.throws(() => summarizeModerationFeedback([{...row,count:Number.MAX_SAFE_INTEGER},{...row,rating:'incorrect'}]), /large/);
  assert.throws(() => summarizeModerationFeedback([{...row,content:'text'}]), /Invalid/);
  assert.throws(() => summarizeModerationFeedback([{...row,count:-1}]), /Invalid/);
});
