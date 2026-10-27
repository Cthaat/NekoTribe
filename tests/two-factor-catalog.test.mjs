import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { describeStep, planSchema } from '../server/database/schema.mjs';
import { schemaFeatures } from '../server/database/schema-definition.mjs';

const catalog = JSON.parse(readFileSync(new URL('../specifications/requirements/two-factor-schema-catalog.json', import.meta.url), 'utf8'));

test('shared 2FA catalog follows the actual Nuxt schema source and all migration checksums', () => {
  assert.equal(catalog.id, 'AUTH-2FA-SCHEMA-CATALOG');
  for (const source of catalog.sources) {
    const content = readFileSync(new URL(`../${source.path}`, import.meta.url), 'utf8').replaceAll('\r\n', '\n');
    assert.equal(createHash('sha256').update(content).digest('hex'), source.sha256, source.path);
  }
  const steps = schemaFeatures.find(item => item.id === 'two-factor').steps.map(item => {
    const step = describeStep(item);
    if (step.kind !== 'index') return step;
    const match = step.sql.match(/ON\s+(\w+)\s*\(([^)]+)\)/);
    return {...step, table: match[1].toUpperCase(), columns: match[2].split(',').map(value => value.trim().toUpperCase())};
  });
  assert.deepEqual(catalog.feature, {id: 'two-factor', steps});
  assert.deepEqual(catalog.migrationChecksums, Object.fromEntries(planSchema().flatMap(group => group.steps.map(step => [step.id, step.checksum]))));
  assert.deepEqual(catalog.ledger, describeStep({id: 'ledger', kind: 'table', name: 'N_SCHEMA_MIGRATIONS', sql: 'CREATE TABLE N_SCHEMA_MIGRATIONS (step_id VARCHAR2(128) PRIMARY KEY, checksum VARCHAR2(64) NOT NULL, applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL)'}));
});
