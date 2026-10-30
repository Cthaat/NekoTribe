import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { schemaFeatures } from '../server/database/schema-definition.mjs';
import { describeStep, planSchema } from '../server/database/schema.mjs';
import { schemaFixture } from '../tests/helpers/schema-fixture.mjs';

const output = new URL('../specifications/requirements/user-settings-schema-catalog.json', import.meta.url);
const feature = schemaFeatures.find(value => value.id === 'user-settings');
if (!feature || feature.steps.length !== 5) throw new Error('User settings schema changed; review catalog.');
const ledger = describeStep({ id: 'ledger', kind: 'table', name: 'N_SCHEMA_MIGRATIONS', sql: 'CREATE TABLE N_SCHEMA_MIGRATIONS (step_id VARCHAR2(128) PRIMARY KEY, checksum VARCHAR2(64) NOT NULL, applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL)' });
const sources = ['server/database/schema-definition.mjs', 'server/database/schema.mjs'].map(path => ({ path, sha256: createHash('sha256').update(readFileSync(new URL(`../${path}`, import.meta.url), 'utf8').replaceAll('\r\n', '\n')).digest('hex') }));
const catalog = { id: 'USER-SETTINGS-SCHEMA-CATALOG', revision: 1, scope: 'Read-only Nuxt user settings feature expectations; absence of ledger is allowed', sources, ledger, migrationChecksums: Object.fromEntries(planSchema().flatMap(group => group.steps.map(step => [step.id, step.checksum]))), feature: { id: 'user-settings', steps: feature.steps.map(describeStep) } };
const auth = JSON.parse(readFileSync(new URL('../specifications/scenarios/two-factor-readiness.json', import.meta.url), 'utf8')).baseline;
const baseline = { owner: auth.owner, ledgerPresent: true, tables: { N_SCHEMA_MIGRATIONS: auth.tables.N_SCHEMA_MIGRATIONS, N_USER_SETTINGS: schemaFixture().state.tables.get('N_USER_SETTINGS') }, records: auth.records, sequences: {}, indexes: {} };
const change = (op, path, value) => ({ op, path, ...(op === 'set' ? { value } : {}) });
const vectors = { id: 'USER-SETTINGS-READINESS', revision: 1, baseline, cases: [
  { id: 'SETTINGS-01', ready: true, mutations: [] },
  { id: 'SETTINGS-02', ready: true, mutations: [change('set', ['ledgerPresent'], false)] },
  { id: 'SETTINGS-03', ready: false, mutations: [change('set', ['owner', 'schema'], 'OTHER')] },
  { id: 'SETTINGS-04', ready: false, mutations: [change('delete', ['tables', 'N_USER_SETTINGS', 'columns', 0])] },
  { id: 'SETTINGS-05', ready: false, mutations: [change('set', ['tables', 'N_USER_SETTINGS', 'columns', 1, 'CHAR_LENGTH'], 127)] },
  { id: 'SETTINGS-06', ready: false, mutations: [change('set', ['tables', 'N_USER_SETTINGS', 'columns', 2, 'DATA_DEFAULT'], '0')] },
  { id: 'SETTINGS-07', ready: false, mutations: [change('delete', ['tables', 'N_USER_SETTINGS', 'constraints', 0])] },
  { id: 'SETTINGS-08', ready: false, mutations: [change('set', ['records', 0, 'CHECKSUM'], 'bad')] }
] };
for (const [url, data] of [[output, catalog], [new URL('../specifications/scenarios/user-settings-readiness.json', import.meta.url), vectors]]) {
  const text = JSON.stringify(data, null, 2) + '\n';
  if (process.argv[2] === '--write') writeFileSync(url, text);
  else if (process.argv[2] === '--check') {
    if (readFileSync(url, 'utf8').replaceAll('\r\n', '\n') !== text) throw new Error('User settings schema data is stale.');
  } else throw new Error('Use --write or --check');
}
if (process.argv[2] === '--check') console.log('User settings schema catalog and scenarios match Nuxt sources.');
