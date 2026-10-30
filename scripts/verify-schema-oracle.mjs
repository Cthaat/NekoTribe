// Explicit destructive fixtures ONLY inside a newly provisioned disposable test schema.
// No dotenv loading: never inherit the application's development database configuration.
import assert from 'node:assert/strict';
import { applySchema, assertSchemaReady, checkSchema, planSchema } from '../server/database/schema.mjs';
import { loadOracleDriver } from './migrate-db.mjs';

const user = process.env.NEKO_ORACLE_TEST_USER;
const password = process.env.NEKO_ORACLE_TEST_PASSWORD;
const connectString = process.env.NEKO_ORACLE_TEST_CONNECT;
if (process.env.NEKO_ORACLE_TEST_DISPOSABLE !== 'true' || !/^NEKO_T13_[A-Z0-9_]+$/.test(user ?? '') || !password || !connectString) {
  throw new Error('Provide an explicitly disposable NEKO_T13_* schema using NEKO_ORACLE_TEST_* environment variables.');
}
const imported = await loadOracleDriver();
const driver = imported.default ?? imported;
const config = { user, password, connectString };
const connection = await driver.getConnection(config);
const contender = await driver.getConnection(config);
const calls = [];
const execute = async (target, sql, binds = {}) => target.execute(sql,
  Object.fromEntries(Object.entries(binds).map(([key, value]) => [key,
    value && typeof value === 'object' && value.out === 'number' ? { dir: driver.BIND_OUT, type: driver.NUMBER } : value
  ])), { outFormat: driver.OUT_FORMAT_OBJECT, autoCommit: true });
const direct = (sql, binds) => execute(connection, sql, binds);
const adapter = { async execute(sql, binds) { calls.push(sql); return direct(sql, binds); } };
const competing = { execute: (sql, binds) => execute(contender, sql, binds) };
const observations = [];
const passed = name => { observations.push(name); console.log(`PASS ${name}`); };
try {
  const identity = await direct("SELECT USER AS NAME, SYS_CONTEXT('USERENV','CURRENT_SCHEMA') AS OWNER FROM dual");
  assert.equal(identity.rows[0].NAME, user);
  assert.equal(identity.rows[0].OWNER, user);
  const objects = await direct('SELECT COUNT(*) AS TOTAL FROM user_objects');
  assert.equal(objects.rows[0].TOTAL, 0, 'Test schema must be completely empty; existing data is never adopted.');
  for (const sql of [
    'CREATE TABLE n_users (user_id NUMBER(10) PRIMARY KEY)',
    'CREATE TABLE n_groups (group_id NUMBER(10) PRIMARY KEY)',
    'CREATE TABLE n_user_settings (user_id NUMBER(10) PRIMARY KEY)',
    'CREATE TABLE n_media_assets (media_id NUMBER(15) PRIMARY KEY)',
    'INSERT INTO n_users (user_id) VALUES (42)',
    'INSERT INTO n_groups (group_id) VALUES (42)',
    'INSERT INTO n_user_settings (user_id) VALUES (42)',
    'INSERT INTO n_media_assets (media_id) VALUES (42)'
  ]) await direct(sql);
  await assert.rejects(assertSchemaReady(adapter, 'two-factor'));
  assert(calls.every(sql => /^SELECT\b/.test(sql)));
  passed('readiness rejects missing objects without DDL');

  let heldAcrossDdl = false;
  const interrupted = { async execute(sql, binds) {
    if (sql.startsWith('ALTER TABLE n_media_assets')) throw new Error('Injected interruption before media step');
    const result = await adapter.execute(sql, binds);
    if (sql.startsWith('CREATE TABLE N_SCHEMA_MIGRATIONS')) {
      await assert.rejects(applySchema(competing), /Cannot acquire/);
      heldAcrossDdl = true;
    }
    return result;
  } };
  await assert.rejects(applySchema(interrupted), /Injected interruption/);
  assert(heldAcrossDdl);
  assert.equal((await direct("SELECT COUNT(*) AS TOTAL FROM n_schema_migrations WHERE step_id = 't13-media-n_media_assets.description'")).rows[0].TOTAL, 0);
  passed('session lock survives DDL commits and failed step is not recorded');
  const expectedSteps = planSchema().flatMap(feature => feature.steps).length;
  assert.deepEqual(await applySchema(competing), { steps: expectedSteps });
  const ready = await checkSchema(adapter);
  assert.equal(ready.length, expectedSteps);
  assert(ready.every(step => step.status === 'ready' && step.recorded), JSON.stringify(ready.filter(step => step.status !== 'ready')));
  passed(`another connection resumes interruption and verifies all ${expectedSteps} steps`);

  const before = calls.length;
  await applySchema(adapter);
  assert(!calls.slice(before).some(sql => /^(CREATE|ALTER|DROP|INSERT|UPDATE|DELETE|MERGE)\b/.test(sql)));
  passed('repeated migration performs no DDL or business DML');
  await direct("UPDATE n_moderation_settings SET setting_value = '168', label = 'custom label' WHERE setting_key = 'default_mute_hours'");
  await direct("INSERT INTO n_user_two_factor_recovery_codes (recovery_code_id,user_id,code_hash) VALUES (57,42,'fixture-only')");
  await direct('DROP SEQUENCE seq_2fa_recovery_code_id');
  await applySchema(adapter);
  assert.equal((await direct('SELECT seq_2fa_recovery_code_id.NEXTVAL AS NEXT_ID FROM dual')).rows[0].NEXT_ID, 58);
  const setting = (await direct("SELECT setting_value,label FROM n_moderation_settings WHERE setting_key = 'default_mute_hours'")).rows[0];
  assert.deepEqual(setting, { SETTING_VALUE: '168', LABEL: 'custom label' });
  await applySchema(adapter);
  assert.equal((await direct('SELECT seq_2fa_recovery_code_id.NEXTVAL AS NEXT_ID FROM dual')).rows[0].NEXT_ID, 59);
  assert.equal((await direct('SELECT COUNT(*) AS TOTAL FROM n_media_assets WHERE media_id = 42')).rows[0].TOTAL, 1);
  passed('existing rows/settings preserved and sequences resume above retained IDs');

  await direct('ALTER TABLE n_moderation_reports DROP CONSTRAINT ck_mod_reports_target');
  await direct("ALTER TABLE n_moderation_reports ADD CONSTRAINT ck_mod_reports_target CHECK (target_type IN ('post','comment','user'))");
  await applySchema(adapter);
  await direct("INSERT INTO n_moderation_reports (report_id,target_type,target_id,reason) VALUES (42,'group_post',42,'spam')");
  passed('legacy target constraint upgraded and group reports accepted');
  await direct('ALTER TABLE n_media_assets MODIFY (description VARCHAR2(999))');
  await assert.rejects(assertSchemaReady(adapter, 'media'));
  await assert.rejects(applySchema(adapter), /Incompatible/);
  await direct('ALTER TABLE n_media_assets MODIFY (description VARCHAR2(1000))');
  await assertSchemaReady(adapter, 'media');
  passed('later schema drift rejected and independently rechecked');
  const recorded = (await direct('SELECT step_id,checksum FROM n_schema_migrations ORDER BY step_id')).rows[0];
  await direct("UPDATE n_schema_migrations SET checksum = 'drift' WHERE step_id = :id", { id: recorded.STEP_ID });
  await assert.rejects(applySchema(adapter), /checksum drift/);
  await direct('UPDATE n_schema_migrations SET checksum = :checksum WHERE step_id = :id', { checksum: recorded.CHECKSUM, id: recorded.STEP_ID });
  await applySchema(adapter);
  passed('ledger checksum drift rejected without marking success');
  console.log(JSON.stringify({ engine: connection.oracleServerVersionString, schema: user, observations, migrationSteps: expectedSteps }));
} finally {
  await contender.close();
  await connection.close();
}
