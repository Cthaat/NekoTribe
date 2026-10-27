import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { assertSchemaReady } from '../server/database/schema.mjs';
import { schemaFixture } from './helpers/schema-fixture.mjs';

const vectors = JSON.parse(readFileSync(new URL('../specifications/scenarios/two-factor-readiness.json', import.meta.url), 'utf8'));

function applyMutation(snapshot, mutation) {
  const parent = mutation.path.slice(0, -1).reduce((value, part) => value[part], snapshot);
  const key = mutation.path.at(-1);
  if (mutation.op === 'set') parent[key] = mutation.value;
  else if (mutation.op === 'delete' && Array.isArray(parent)) parent.splice(key, 1);
  else if (mutation.op === 'delete') delete parent[key];
  else throw new Error('Unknown fixture mutation');
}

for (const vector of vectors.cases) {
  test(`Nuxt two-factor readiness: ${vector.id}`, async () => {
    const snapshot = structuredClone(vectors.baseline);
    for (const mutation of vector.mutations) applyMutation(snapshot, mutation);
    const adapter = schemaFixture();
    adapter.state.tables = new Map(Object.entries(snapshot.tables));
    if (!snapshot.ledgerPresent) adapter.state.tables.delete('N_SCHEMA_MIGRATIONS');
    adapter.state.sequences = new Map(Object.entries(snapshot.sequences));
    adapter.state.indexes = new Map(Object.entries(snapshot.indexes));
    adapter.state.records = new Map(snapshot.records.map(row => [row.STEP_ID, row.CHECKSUM]));
    const execute = adapter.execute.bind(adapter);
    adapter.execute = async (sql, binds) => {
      if (/^SELECT USER AS/i.test(sql)) return {rows: [{USER_NAME: snapshot.owner.user, SCHEMA_NAME: snapshot.owner.schema}]};
      assert.match(sql.trim(), /^SELECT\b/i);
      return execute(sql, binds);
    };
    if (vector.ready) await assertSchemaReady(adapter, 'two-factor');
    else await assert.rejects(assertSchemaReady(adapter, 'two-factor'));
  });
}
