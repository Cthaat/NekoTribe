import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { schemaFixture } from './helpers/schema-fixture.mjs';
import { assertSchemaReady } from '../server/database/schema.mjs';

test('Skill schema catalog and scenarios match the migration authority', () => {
  execFileSync(process.execPath, [fileURLToPath(new URL('../scripts/ai-skill-schema-catalog.mjs', import.meta.url)), '--check']);
});

test('shared Skill readiness scenarios match Nuxt migration checks', async () => {
  const fixture = JSON.parse(readFileSync(new URL('../specifications/scenarios/ai-skill-readiness.json', import.meta.url), 'utf8'));
  assert.equal(fixture.id, 'AI-SKILL-READINESS');
  for (const scenario of fixture.cases) {
    const snapshot = structuredClone(fixture.baseline);
    for (const mutation of scenario.mutations) {
      const key = mutation.path.at(-1);
      const parent = mutation.path.slice(0, -1).reduce((value, part) => value[part], snapshot);
      if (mutation.op === 'set') parent[key] = mutation.value;
      else if (mutation.op === 'delete' && Array.isArray(parent)) parent.splice(key, 1);
      else if (mutation.op === 'delete') delete parent[key];
      else throw new Error('Unknown fixture mutation');
    }
    const db = schemaFixture();
    db.state.tables = new Map(Object.entries(snapshot.tables));
    if (!snapshot.ledgerPresent) db.state.tables.delete('N_SCHEMA_MIGRATIONS');
    db.state.records = new Map(snapshot.records.map(row => [row.STEP_ID, row.CHECKSUM]));
    const execute = db.execute;
    db.execute = (sql, binds) => sql.toUpperCase().startsWith('SELECT USER AS')
      ? Promise.resolve({ rows: [{ USER_NAME: snapshot.owner.user, SCHEMA_NAME: snapshot.owner.schema }] })
      : execute(sql, binds);
    let ready = true;
    try { await assertSchemaReady(db, 'ai-skills'); } catch { ready = false; }
    assert.equal(ready, scenario.ready, scenario.id);
    assert(db.state.calls.every(call => /^SELECT\b/i.test(call.sql)), scenario.id);
  }
});
