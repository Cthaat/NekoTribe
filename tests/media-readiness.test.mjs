import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {test} from 'node:test';
import {assertSchemaReady} from '../server/database/schema.mjs';
import {schemaFixture} from './helpers/schema-fixture.mjs';
const fixture=JSON.parse(readFileSync(new URL('../specifications/scenarios/media-readiness.json',import.meta.url),'utf8'));
function mutate(snapshot,m){const parent=m.path.slice(0,-1).reduce((v,k)=>v[k],snapshot),key=m.path.at(-1);if(m.op==='set')parent[key]=m.value;else if(Array.isArray(parent))parent.splice(key,1);else delete parent[key]}
for(const c of fixture.cases)test(`Nuxt media readiness: ${c.id}`,async()=>{
 const data=structuredClone(fixture.baseline);for(const m of c.mutations)mutate(data,m);
 const db=schemaFixture();db.state.tables=new Map(Object.entries(data.tables));if(!data.ledgerPresent)db.state.tables.delete('N_SCHEMA_MIGRATIONS');db.state.records=new Map(data.records.map(x=>[x.STEP_ID,x.CHECKSUM]));
 const run=db.execute.bind(db);db.execute=async(sql,binds)=>{assert.match(sql.trim(),/^SELECT\b/i);if(/^SELECT USER AS/i.test(sql))return {rows:[{USER_NAME:data.owner.user,SCHEMA_NAME:data.owner.schema}]};return run(sql,binds)};
 if(c.ready)await assertSchemaReady(db,'media');else await assert.rejects(assertSchemaReady(db,'media'));
});
