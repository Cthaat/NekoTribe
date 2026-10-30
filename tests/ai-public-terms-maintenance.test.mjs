import assert from 'node:assert/strict';
import {test} from 'node:test';
import {mkdtempSync,mkdirSync,writeFileSync,copyFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
import {maintainTerms} from '../scripts/ai-public-terms-maintenance.mjs';
import {schemaFixture} from './helpers/schema-fixture.mjs';
import {applySchema} from '../server/database/schema.mjs';
import {buildTermsMaintenanceBundle} from '../scripts/lib/ai-public-terms-build.mjs';

const secret='secret-do-not-log';
const env={ORACLE_USER:'test',ORACLE_PASSWORD:secret,ORACLE_HOST:'localhost',ORACLE_PORT:'1521',ORACLE_SERVICE_NAME:'test'};
test('default plan remains offline; connected actions require explicit dotenv and exact generation',async()=>{
 let loads=0;const output=[];const runtime={termsCatalogDigest:()=> 'd'.repeat(64)};
 const plan=await maintainTerms({args:[],loadRuntime:async()=>runtime,loadDriver:async()=>{loads++;throw Error()},output:s=>output.push(s)});
 assert.equal(plan.mode,'plan');assert.equal(loads,0);assert(!output.join('').includes(secret));
 for(const args of [['--publish','--expected','0'],['--disable','--expected','0','--dotenv','x'],['--publish','--expected','1e3','--dotenv','x'],['--status','--expected','1','--dotenv','x'],['--publish','--dotenv','x']]) await assert.rejects(()=>maintainTerms({args,loadDriver:async()=>{loads++}}));
 assert.equal(loads,0);
});
test('explicit publication calls one dedicated connection and never leaks secrets',async()=>{
 let closed=0,received;const output=[];const connection={async close(){closed++}};
 const runtime={termsCatalogDigest:()=> 'd'.repeat(64),async changeTermsAuthority(conn,change){assert.equal(conn,connection);received=change;return {generation:2,digest:'d'.repeat(64),enabled:true}}};
 const result=await maintainTerms({args:['--publish','--expected','1','--dotenv','fixture'],env,readEnv:()=>({}),loadRuntime:async()=>runtime,loadDriver:async()=>({getConnection:async()=>connection}),output:s=>output.push(s)});
 assert.equal(result.generation,2);assert.equal(received.expectedGeneration,1);assert.equal(received.action,'publish');assert.equal(closed,1);assert(!output.join('').includes(secret));
});
test('status is read-only and uncertain commit is surfaced without retry or secret',async()=>{
 let calls=0;const connection={async execute(sql){assert.match(sql,/^SELECT\b/);calls++;return {rows:[{CATALOG_DIGEST:'a'.repeat(64),GENERATION:4,ENABLED:1}]}},async close(){}};
 const runtime={termsCatalogDigest:()=> 'd'.repeat(64),async changeTermsAuthority(){calls++;throw Error('TERMS_AUTHORITY_COMMIT_UNCERTAIN')}};
 const opts={env,readEnv:()=>({}),loadRuntime:async()=>runtime,loadDriver:async()=>({OUT_FORMAT_OBJECT:4002,getConnection:async()=>connection}),output:()=>{}};
 assert.equal((await maintainTerms({...opts,args:['--status','--dotenv','fixture']})).generation,4);
 await assert.rejects(()=>maintainTerms({...opts,args:['--disable','--expected','4','--dotenv','fixture']}),e=>e.message==='TERMS_AUTHORITY_COMMIT_UNCERTAIN');assert.equal(calls,2);
});
test('actual bundled maintenance component checks schema and writes through the supplied connection',async()=>{
 const fixture=schemaFixture();await applySchema(fixture);let commits=0,closed=0,writes=0;
 const connection={async execute(sql,binds,options){if(/^INSERT INTO n_ai_terms_active/i.test(sql)){writes++;assert.equal(options.autoCommit,false);assert.match(binds.digest,/^[a-f0-9]{64}$/);return {rowsAffected:1}}return fixture.execute(sql,binds)},async commit(){commits++},async rollback(){throw Error('unexpected rollback')},async close(){closed++}};
 const result=await maintainTerms({args:['--publish','--expected','0','--dotenv','fixture'],env,readEnv:()=>({}),loadDriver:async()=>({getConnection:async()=>connection}),output:()=>{}});
 assert.equal(result.generation,1);assert.equal(writes,1);assert.equal(commits,1);assert.equal(closed,1);
});
test('connection cleanup failure never prints a misleading success',async()=>{
 const output=[];const connection={async close(){throw Error('secret')}};
 const runtime={termsCatalogDigest:()=> 'd'.repeat(64),async changeTermsAuthority(){return {generation:2,enabled:false}}};
 await assert.rejects(()=>maintainTerms({args:['--disable','--expected','1','--dotenv','fixture'],env,readEnv:()=>({}),loadRuntime:async()=>runtime,loadDriver:async()=>({getConnection:async()=>connection}),output:s=>output.push(s)}),/TERMS_AUTHORITY_CONNECTION_CLOSE_FAILED/);
 assert.deepEqual(output,[]);
});
test('packaged runtime can execute offline without source files or development dependencies',async()=>{
 const path=mkdtempSync(join(tmpdir(),'neko-terms-'));
 try {
  const scripts=join(path,'scripts'),server=join(path,'.output','server'),spec=join(path,'specifications','requirements'),database=join(path,'server','database');mkdirSync(scripts,{recursive:true});mkdirSync(join(server,'node_modules','oracledb'),{recursive:true});mkdirSync(spec,{recursive:true});mkdirSync(database,{recursive:true});
  copyFileSync(new URL('../scripts/ai-public-terms-maintenance.mjs',import.meta.url),join(scripts,'ai-public-terms-maintenance.mjs'));
  copyFileSync(new URL('../scripts/migrate-db.mjs',import.meta.url),join(scripts,'migrate-db.mjs'));
  for(const name of ['schema.mjs','schema-definition.mjs'])copyFileSync(new URL(`../server/database/${name}`,import.meta.url),join(database,name));
  copyFileSync(new URL('../specifications/requirements/ai-public-terms-catalog.json',import.meta.url),join(spec,'ai-public-terms-catalog.json'));
  writeFileSync(join(server,'index.mjs'),'');
  writeFileSync(join(server,'node_modules','oracledb','index.js'),`module.exports={OUT_FORMAT_OBJECT:4002,async getConnection(){return {async execute(sql){if(!/^SELECT/.test(sql))throw Error('unexpected write');return {rows:[{CATALOG_DIGEST:'a'.repeat(64),GENERATION:3,ENABLED:1}]}},async close(){}}}}`);
  await buildTermsMaintenanceBundle({outfile:join(server,'ai-terms-maintenance.cjs')});
  const result=spawnSync(process.execPath,[join(scripts,'ai-public-terms-maintenance.mjs'),'--plan'],{encoding:'utf8',env:{...process.env,NEKO_TERMS_PACKAGED:'1'}});
  assert.equal(result.status,0,result.stderr);const plan=JSON.parse(result.stdout);assert.equal(plan.connected,false);assert.match(plan.digest,/^[a-f0-9]{64}$/);
  const dotenv=join(path,'fixture.env');writeFileSync(dotenv,'ORACLE_USER=test\nORACLE_PASSWORD=test\nORACLE_HOST=localhost\nORACLE_PORT=1521\nORACLE_SERVICE_NAME=test\n');
  const status=spawnSync(process.execPath,[join(scripts,'ai-public-terms-maintenance.mjs'),'--status','--dotenv',dotenv],{encoding:'utf8',env:{...process.env,NEKO_TERMS_PACKAGED:'1',NUXT_ORACLE_USER:'test',NUXT_ORACLE_PASSWORD:'test',NUXT_ORACLE_HOST:'localhost',NUXT_ORACLE_PORT:'1521',NUXT_ORACLE_SERVICE_NAME:'test'}});
  assert.equal(status.status,0,status.stderr);assert.equal(JSON.parse(status.stdout).generation,3);
 } finally {rmSync(path,{recursive:true,force:true})}
});
