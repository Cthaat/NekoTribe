import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { schemaFeatures } from '../server/database/schema-definition.mjs';
import { describeStep, planSchema } from '../server/database/schema.mjs';
import { schemaFixture } from '../tests/helpers/schema-fixture.mjs';

const feature = schemaFeatures.find(value => value.id === 'ai-conversations');
if (!feature || feature.steps.length !== 5) throw new Error('AI conversation schema changed; review catalog.');
const ledger = describeStep({ id: 'ledger', kind: 'table', name: 'N_SCHEMA_MIGRATIONS', sql: 'CREATE TABLE N_SCHEMA_MIGRATIONS (step_id VARCHAR2(128) PRIMARY KEY, checksum VARCHAR2(64) NOT NULL, applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL)' });
const sources = ['server/database/schema-definition.mjs', 'server/database/schema.mjs'].map(path => ({ path, sha256: createHash('sha256').update(readFileSync(new URL(`../${path}`, import.meta.url), 'utf8').replaceAll('\r\n', '\n')).digest('hex') }));
const descriptions = feature.steps.map(describeStep);
const steps = descriptions.map(step => {
  if (step.kind === 'table') {
    const widened = descriptions.filter(later => later.table === step.table && later.previousType)
      .map(later => later.columns[0].name);
    // Each widened column is checked by its own step. The CREATE step retains its checksum.
    return { ...step, columns: step.columns.filter(column => !widened.includes(column.name)) };
  }
  if (step.kind !== 'index') return step;
  const match = step.sql.match(/ON\s+(\w+)\s*\(([^)]+)\)/);
  if (!match) throw new Error('Unsupported index definition.');
  return { ...step, table: match[1].toUpperCase(), columns: match[2].split(',').map(value => value.trim().toUpperCase()) };
});
const catalog = { id: 'AI-CONVERSATION-SCHEMA-CATALOG', revision: 3, scope: 'Read-only shared AI conversation schema; absence of ledger is allowed', sources, ledger, migrationChecksums: Object.fromEntries(planSchema().flatMap(group => group.steps.map(step => [step.id, step.checksum]))), feature: { id: 'ai-conversations', steps } };
const auth = JSON.parse(readFileSync(new URL('../specifications/scenarios/two-factor-readiness.json', import.meta.url), 'utf8')).baseline;
const state = schemaFixture().state;
const baseline = { owner: auth.owner, ledgerPresent: true, tables: { N_SCHEMA_MIGRATIONS: auth.tables.N_SCHEMA_MIGRATIONS, N_AI_CONVERSATIONS: state.tables.get('N_AI_CONVERSATIONS'), N_AI_MESSAGES: state.tables.get('N_AI_MESSAGES') }, records: auth.records, sequences: {}, indexes: { IDX_AI_CONV_OWNER: state.indexes.get('IDX_AI_CONV_OWNER') } };
const change = (op, path, value) => ({ op, path, ...(op === 'set' ? { value } : {}) });
const titleIndex = baseline.tables.N_AI_CONVERSATIONS.columns.findIndex(column => column.COLUMN_NAME === 'TITLE');
const groupIdIndex = baseline.tables.N_AI_CONVERSATIONS.columns.findIndex(column => column.COLUMN_NAME === 'GROUP_ID');
const vectors = { id: 'AI-CONVERSATION-READINESS', revision: 3, baseline, cases: [
  { id: 'AI-SCHEMA-01', ready: true, mutations: [] },
  { id: 'AI-SCHEMA-02', ready: true, mutations: [change('set', ['ledgerPresent'], false)] },
  { id: 'AI-SCHEMA-03', ready: false, mutations: [change('set', ['owner', 'schema'], 'OTHER')] },
  { id: 'AI-SCHEMA-04', ready: false, mutations: [change('delete', ['tables', 'N_AI_CONVERSATIONS'])] },
  { id: 'AI-SCHEMA-05', ready: false, mutations: [change('delete', ['tables', 'N_AI_MESSAGES', 'columns', 0])] },
  { id: 'AI-SCHEMA-06', ready: false, mutations: [change('delete', ['tables', 'N_AI_MESSAGES', 'constraints', 1])] },
  { id: 'AI-SCHEMA-07', ready: false, mutations: [change('delete', ['indexes', 'IDX_AI_CONV_OWNER'])] },
  { id: 'AI-SCHEMA-08', ready: false, mutations: [change('set', ['records', 0, 'CHECKSUM'], 'bad')] },
  { id: 'AI-SCHEMA-09', ready: false, mutations: [change('set', ['tables', 'N_AI_CONVERSATIONS', 'columns', titleIndex, 'CHAR_USED'], 'B')] },
  { id: 'AI-SCHEMA-10', ready: false, mutations: [change('set', ['tables', 'N_AI_CONVERSATIONS', 'columns', groupIdIndex, 'DATA_PRECISION'], 15)] }
] };
for (const [path, value] of [['../specifications/requirements/ai-conversation-schema-catalog.json', catalog], ['../specifications/scenarios/ai-conversation-readiness.json', vectors]]) {
  const output = new URL(path, import.meta.url); const text = JSON.stringify(value, null, 2) + '\n';
  if (process.argv[2] === '--write') writeFileSync(output, text);
  else if (process.argv[2] === '--check') {
    if (readFileSync(output, 'utf8').replaceAll('\r\n', '\n') !== text) throw new Error('AI conversation schema data is stale.');
  } else throw new Error('Use --write or --check');
}
if (process.argv[2] === '--check') console.log('AI conversation schema catalog and scenarios match migration definitions.');
