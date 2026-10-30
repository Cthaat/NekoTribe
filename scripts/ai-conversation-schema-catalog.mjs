import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { schemaFeatures } from '../server/database/schema-definition.mjs';
import { describeStep, planSchema } from '../server/database/schema.mjs';

const feature = schemaFeatures.find(value => value.id === 'ai-conversations');
if (!feature || feature.steps.length !== 3) throw new Error('AI conversation schema changed; review catalog.');
const ledger = describeStep({ id: 'ledger', kind: 'table', name: 'N_SCHEMA_MIGRATIONS', sql: 'CREATE TABLE N_SCHEMA_MIGRATIONS (step_id VARCHAR2(128) PRIMARY KEY, checksum VARCHAR2(64) NOT NULL, applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL)' });
const sources = ['server/database/schema-definition.mjs', 'server/database/schema.mjs'].map(path => ({ path, sha256: createHash('sha256').update(readFileSync(new URL(`../${path}`, import.meta.url), 'utf8').replaceAll('\r\n', '\n')).digest('hex') }));
const steps = feature.steps.map(item => {
  const step = describeStep(item);
  if (step.kind !== 'index') return step;
  const match = step.sql.match(/ON\s+(\w+)\s*\(([^)]+)\)/);
  if (!match) throw new Error('Unsupported index definition.');
  return { ...step, table: match[1].toUpperCase(), columns: match[2].split(',').map(value => value.trim().toUpperCase()) };
});
const catalog = { id: 'AI-CONVERSATION-SCHEMA-CATALOG', revision: 1, scope: 'Read-only shared AI conversation schema; absence of ledger is allowed', sources, ledger, migrationChecksums: Object.fromEntries(planSchema().flatMap(group => group.steps.map(step => [step.id, step.checksum]))), feature: { id: 'ai-conversations', steps } };
const output = new URL('../specifications/requirements/ai-conversation-schema-catalog.json', import.meta.url);
const text = JSON.stringify(catalog, null, 2) + '\n';
if (process.argv[2] === '--write') writeFileSync(output, text);
else if (process.argv[2] === '--check') {
  if (readFileSync(output, 'utf8').replaceAll('\r\n', '\n') !== text) throw new Error('AI conversation schema catalog is stale.');
  console.log('AI conversation schema catalog matches migration definitions.');
} else throw new Error('Use --write or --check');
