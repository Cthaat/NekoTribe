import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { schemaFeatures } from '../../server/database/schema-definition.mjs';
import { describeIndex, describeStep, planSchema } from '../../server/database/schema.mjs';

export function syncSchemaCatalog({featureId,revision,expectedSteps,scope}) {
  const feature = schemaFeatures.find(item => item.id === featureId);
  if (!feature || feature.steps.length !== expectedSteps) throw new Error(`Review ${featureId} migration.`);
  const sources = ['server/database/schema-definition.mjs','server/database/schema.mjs'].map(path => ({
    path,
    sha256: createHash('sha256').update(readFileSync(new URL(`../../${path}`,import.meta.url),'utf8').replaceAll('\r\n','\n')).digest('hex'),
  }));
  const ledger = describeStep({ id:'ledger',kind:'table',name:'N_SCHEMA_MIGRATIONS',
    sql:'CREATE TABLE N_SCHEMA_MIGRATIONS (step_id VARCHAR2(128) PRIMARY KEY, checksum VARCHAR2(64) NOT NULL, applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL)' });
  const migrationChecksums = Object.fromEntries(planSchema().flatMap(group => group.steps.map(step => [step.id,step.checksum])));
  const steps = feature.steps.map(step => step.kind === 'index' ? { ...step, ...describeIndex(step) } : describeStep(step));
  const catalog = {id:`${featureId.toUpperCase()}-SCHEMA-CATALOG`,revision,scope,sources,ledger,migrationChecksums,
    feature:{id:feature.id,steps}};
  const output = new URL(`../../specifications/requirements/${featureId}-schema-catalog.json`,import.meta.url);
  const text = JSON.stringify(catalog,null,2) + '\n';
  if (process.argv[2] === '--write') writeFileSync(output,text);
  else if (process.argv[2] === '--check') {
    if (readFileSync(output,'utf8').replaceAll('\r\n','\n') !== text) throw new Error(`${featureId} schema catalog is stale.`);
  } else throw new Error('Use --write or --check');
}
