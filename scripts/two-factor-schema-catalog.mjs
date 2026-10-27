import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { schemaFeatures } from '../server/database/schema-definition.mjs';
import { describeStep, planSchema } from '../server/database/schema.mjs';

const output = new URL('../specifications/requirements/two-factor-schema-catalog.json', import.meta.url);
const feature = schemaFeatures.find(value => value.id === 'two-factor');
if (!feature) throw new Error('Missing two-factor feature');
const ledger = describeStep({id:'ledger',kind:'table',name:'N_SCHEMA_MIGRATIONS',sql:'CREATE TABLE N_SCHEMA_MIGRATIONS (step_id VARCHAR2(128) PRIMARY KEY, checksum VARCHAR2(64) NOT NULL, applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL)'});
const sources = ['server/database/schema-definition.mjs','server/database/schema.mjs'].map(path => ({path,sha256:createHash('sha256').update(readFileSync(new URL(`../${path}`, import.meta.url),'utf8').replaceAll('\r\n','\n')).digest('hex')}));
const steps = feature.steps.map(item => {
  const step = describeStep(item);
  if (step.kind !== 'index') return step;
  const match = step.sql.match(/ON\s+(\w+)\s*\(([^)]+)\)/);
  if (!match) throw new Error('Unsupported index definition');
  return {...step,table:match[1].toUpperCase(),columns:match[2].split(',').map(value=>value.trim().toUpperCase())};
});
const catalog = {id:'AUTH-2FA-SCHEMA-CATALOG',revision:1,scope:'Read-only Nuxt two-factor schema expectations; absence of ledger is allowed',sources,ledger,
  migrationChecksums:Object.fromEntries(planSchema().flatMap(group=>group.steps.map(step=>[step.id,step.checksum]))),feature:{id:'two-factor',steps}};
const result = JSON.stringify(catalog,null,2)+'\n';
if (process.argv[2] === '--write') {
  writeFileSync(output,result);
} else if (process.argv[2] === '--check') {
  if (readFileSync(output,'utf8').replaceAll('\r\n','\n') !== result) throw new Error('Two-factor schema catalog is stale; review and regenerate it before synchronizing all backends.');
  console.log('Two-factor schema catalog matches Nuxt sources.');
} else {
  throw new Error('Use --check or --write.');
}
