import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync, mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { schemaFixture } from './helpers/schema-fixture.mjs';
import { applySchema, assertSchemaReady, checkSchema, planSchema, normalizeExpression, coalesceReadinessCheck } from '../server/database/schema.mjs';
import { schemaFeatures } from '../server/database/schema-definition.mjs';
import { migrateDatabase, loadOracleDriver } from '../scripts/migrate-db.mjs';

const ddl = calls => calls.filter(c => /^(CREATE|ALTER|DROP)\b/.test(c.sql));
test('default plan does not read dotenv, load a driver or connect', async () => {
  let loaded = false; const output = [];
  const plan = await migrateDatabase({ root: '\0invalid-directory', env: { ORACLE_PASSWORD: 'do-not-print' }, loadDriver: () => { loaded = true; throw Error('connected'); }, output: s => output.push(s) });
  assert.equal(loaded, false); assert.equal(plan.length, 20); assert(!output.join('').includes('do-not-print'));
  assert.equal(plan.flatMap(f => f.steps).length, 67);
});
test('the baseline prepares feedback and media access scope through explicit idempotent migrations', async () => {
  const db = schemaFixture({ baseline: true });
  const initial = await checkSchema(db);
  assert.deepEqual(initial.filter(x => x.status !== 'ready').map(x => [x.feature, x.status]), [
    ['ai-conversations', 'missing'],
    ['ai-conversations', 'missing'],
    ['ai-conversations', 'missing'],
    ['recommendation-feedback', 'missing'],
    ['ai-moderation-feedback', 'missing'],
    ['media-access-scope', 'missing'],
    ['ai-user-provider', 'missing'],
    ['direct-message-extras', 'missing'],
    ['direct-message-extras', 'missing'],
    ['direct-message-extras', 'missing'],
    ...Array.from({length:5}, () => ['post-polls', 'missing']),
    ...Array.from({length:4}, () => ['post-drafts', 'missing']),
    ['profile-pinned-post', 'missing'],
    ['post-markdown', 'missing'],
    ...Array.from({length:4}, () => ['passkey-auth', 'missing']),
    ...Array.from({length:3}, () => ['github-oauth', 'missing']),
  ]);
  assert(db.state.calls.every(c => /^SELECT\b/.test(c.sql)));
  await applySchema(db);
  assert.deepEqual(ddl(db.state.calls).map(c => c.sql.split('(')[0].trim().split(/\s+START WITH/i)[0]), [
    'CREATE TABLE N_SCHEMA_MIGRATIONS', 'ALTER TABLE n_ai_conversations MODIFY', 'ALTER TABLE n_ai_conversations MODIFY',
    'ALTER TABLE n_ai_conversations ADD',
    'CREATE TABLE n_recommendation_feedback', 'CREATE TABLE n_ai_moderation_feedback',
    'ALTER TABLE n_media_assets ADD',
    'CREATE TABLE n_ai_user_providers',
    'CREATE TABLE n_direct_message_media', 'CREATE TABLE n_direct_message_replies',
    'CREATE TABLE n_direct_message_reactions',
    'CREATE TABLE n_post_polls', 'CREATE TABLE n_post_poll_options', 'CREATE TABLE n_post_poll_ballots',
    'CREATE TABLE n_post_poll_votes', 'CREATE SEQUENCE seq_post_poll_id',
    'CREATE TABLE n_post_drafts', 'CREATE SEQUENCE seq_post_draft_id',
    'CREATE INDEX idx_post_draft_owner ON n_post_drafts', 'CREATE INDEX idx_post_draft_due ON n_post_drafts',
    'CREATE TABLE n_user_pinned_posts',
    'CREATE TABLE n_post_markdown',
    'CREATE TABLE n_webauthn_credentials', 'CREATE INDEX idx_webauthn_cred_owner ON n_webauthn_credentials',
    'CREATE TABLE n_webauthn_challenges', 'CREATE INDEX idx_webauthn_chall_expiry ON n_webauthn_challenges',
    'CREATE TABLE n_github_oauth_links', 'CREATE TABLE n_github_oauth_flows',
    'CREATE INDEX idx_github_oauth_flow_expiry ON n_github_oauth_flows',
  ]);
  assert((await checkSchema(db, 'recommendation-feedback')).every(item => item.status === 'ready' && item.recorded));
  assert((await checkSchema(db, 'ai-moderation-feedback')).every(item => item.status === 'ready' && item.recorded));
  assert((await checkSchema(db, 'media-access-scope')).every(item => item.status === 'ready' && item.recorded));
  assert((await checkSchema(db, 'ai-user-provider')).every(item => item.status === 'ready' && item.recorded));
  assert((await checkSchema(db, 'direct-message-extras')).every(item => item.status === 'ready' && item.recorded));
  assert((await checkSchema(db, 'post-polls')).every(item => item.status === 'ready' && item.recorded));
  assert((await checkSchema(db, 'post-drafts')).every(item => item.status === 'ready' && item.recorded));
  assert((await checkSchema(db, 'profile-pinned-post')).every(item => item.status === 'ready' && item.recorded));
  assert((await checkSchema(db, 'post-markdown')).every(item => item.status === 'ready' && item.recorded));
  assert((await checkSchema(db, 'passkey-auth')).every(item => item.status === 'ready' && item.recorded));
  assert((await checkSchema(db, 'github-oauth')).every(item => item.status === 'ready' && item.recorded));
  const ballots = db.state.tables.get('N_POST_POLL_BALLOTS');
  assert(ballots.constraints.some(item => item.CONSTRAINT_TYPE === 'P' && item.columns.join(',') === 'POLL_ID,USER_ID'));
  const media = db.state.tables.get('N_MEDIA_ASSETS');
  const scope = media.columns.find(column => column.COLUMN_NAME === 'ACCESS_SCOPE');
  assert.equal(scope.DATA_DEFAULT, "'public'");
  assert.equal(scope.NULLABLE, 'N');
  const knowledgeScope = db.state.tables.get('N_AI_CONVERSATIONS').columns.find(column => column.COLUMN_NAME === 'KNOWLEDGE_SCOPE');
  assert.equal(knowledgeScope.DATA_DEFAULT, "'public'");
  assert.equal(knowledgeScope.NULLABLE, 'N');
  assert(media.constraints.some(constraint =>
    normalizeExpression(constraint.SEARCH_CONDITION_VC) === "ACCESS_SCOPEIN('chat','post','public')"));
  const before = db.state.calls.length;
  await applySchema(db);
  assert.equal(ddl(db.state.calls.slice(before)).length, 0);
  assert(!db.state.calls.slice(before).some(c => /^(INSERT|MERGE|UPDATE|DELETE)\b/.test(c.sql)));
  const baseline = readFileSync(new URL('../data/neko_tribe-oracle-v2.sql', import.meta.url), 'utf8');
  for (const f of schemaFeatures) for (const s of f.steps) {
    if (['ai-conversations', 'post-polls', 'post-drafts', 'passkey-auth', 'github-oauth'].includes(f.id)) continue;
    if (s.kind === 'index') assert(baseline.toUpperCase().includes(s.sql.toUpperCase().split(' ON ')[0]), s.name);
    if (s.kind === 'sequence') assert(baseline.toUpperCase().includes(`CREATE ${s.kind.toUpperCase()} ${s.name}`), s.name);
    if (s.kind === 'seed') assert(baseline.includes(`VALUES ('${s.setting.key}', '${s.setting.value}', '${s.setting.value_type}'`));
  }
});
test('AI conversation migration creates missing tables without changing existing data', async () => {
  const db = schemaFixture({ baseline: true });
  db.state.tables.delete('N_AI_CONVERSATIONS'); db.state.tables.delete('N_AI_MESSAGES'); db.state.indexes.delete('IDX_AI_CONV_OWNER');
  const existing = structuredClone(db.state.tables.get('N_USER_SETTINGS'));
  const pending = await checkSchema(db, 'ai-conversations');
  assert.equal(pending.filter(item => item.status === 'missing').length, 3);
  await applySchema(db);
  assert.deepEqual(db.state.tables.get('N_USER_SETTINGS'), existing);
  assert((await checkSchema(db, 'ai-conversations')).every(item => item.status === 'ready'));
  const title = db.state.tables.get('N_AI_CONVERSATIONS').columns.find(row => row.COLUMN_NAME === 'TITLE');
  assert.equal(title.CHAR_LENGTH, 200);
  assert.equal(title.CHAR_USED, 'C');
  const groupId = db.state.tables.get('N_AI_CONVERSATIONS').columns.find(row => row.COLUMN_NAME === 'GROUP_ID');
  assert.equal(groupId.DATA_PRECISION, 19);
  const count = db.state.calls.length;
  await applySchema(db);
  assert.equal(ddl(db.state.calls.slice(count)).length, 0);
});
test('title migration widens the legacy column and rejects unrelated schema drift', async () => {
  const db = schemaFixture();
  const title = db.state.tables.get('N_AI_CONVERSATIONS').columns.find(row => row.COLUMN_NAME === 'TITLE');
  title.CHAR_USED = 'B';
  const titleStep = async () => (await checkSchema(db, 'ai-conversations')).find(row => row.id === 'ai-conversations-title-char');
  assert.equal((await titleStep()).status, 'missing');
  await assert.rejects(() => assertSchemaReady(db, 'ai-conversations'));
  title.NULLABLE = 'N';
  assert.equal((await titleStep()).status, 'incompatible');
  title.NULLABLE = 'Y';
  await applySchema(db);
  assert.equal((await titleStep()).status, 'ready');
  assert.equal(title.CHAR_USED, 'C');
});
test('group conversation migration widens precision without invalidating the original table step', async () => {
  const db = schemaFixture();
  const groupId = db.state.tables.get('N_AI_CONVERSATIONS').columns.find(row => row.COLUMN_NAME === 'GROUP_ID');
  groupId.DATA_PRECISION = 15;
  const steps = () => checkSchema(db, 'ai-conversations');
  assert.deepEqual((await steps()).filter(row => row.status !== 'ready').map(row => row.id), ['ai-conversations-group-id-precision']);
  groupId.DATA_SCALE = 1;
  assert.equal((await steps()).find(row => row.id === 'ai-conversations-group-id-precision').status, 'incompatible');
  groupId.DATA_SCALE = 0;
  await applySchema(db);
  assert.equal(groupId.DATA_PRECISION, 19);
  assert((await steps()).every(row => row.status === 'ready' && row.recorded));
  const before = db.state.calls.length;
  await applySchema(db);
  assert.deepEqual(ddl(db.state.calls.slice(before)), []);
});
test('terms authority migration creates an empty guarded singleton without publishing rules',async()=>{
 const db=schemaFixture();db.state.tables.delete('N_AI_TERMS_ACTIVE');
 const steps=planSchema().find(feature=>feature.feature==='ai-terms')?.steps;
 assert.equal(steps?.length,1);assert.equal(steps[0].name,'N_AI_TERMS_ACTIVE');
 assert((await checkSchema(db,'ai-terms')).some(step=>step.status==='missing'));
 const before=structuredClone(db.state.tables.get('N_USER_SETTINGS'));
 await applySchema(db);
 assert.deepEqual(db.state.tables.get('N_USER_SETTINGS'),before);
 assert((await checkSchema(db,'ai-terms')).every(step=>step.status==='ready'));
 assert(!db.state.calls.some(call=>/^(INSERT|MERGE|UPDATE)\s+.*N_AI_TERMS_ACTIVE/i.test(call.sql)));
 const count=db.state.calls.length;await applySchema(db);assert.equal(ddl(db.state.calls.slice(count)).length,0);
});
test('skill configuration migration creates an empty singleton without enabling any skill',async()=>{
 const db=schemaFixture();db.state.tables.delete('N_AI_SKILL_CONFIG');
 const steps=planSchema().find(feature=>feature.feature==='ai-skills')?.steps;
 assert.equal(steps?.length,1);assert.equal(steps[0].name,'N_AI_SKILL_CONFIG');
 assert((await checkSchema(db,'ai-skills')).some(step=>step.status==='missing'));
 const existing=structuredClone(db.state.tables.get('N_USER_SETTINGS'));await applySchema(db);
 assert.deepEqual(db.state.tables.get('N_USER_SETTINGS'),existing);
 assert((await checkSchema(db,'ai-skills')).every(step=>step.status==='ready'));
 assert(!db.state.calls.some(call=>/^(INSERT|MERGE|UPDATE)\s+.*N_AI_SKILL_CONFIG/i.test(call.sql)));
 const count=db.state.calls.length;await applySchema(db);assert.equal(ddl(db.state.calls.slice(count)).length,0);
});
test('existing settings and sequence state are preserved; missing settings insert only', async () => {
  const db = schemaFixture();
  db.state.settings.get('default_mute_hours').SETTING_VALUE = '168';
  db.state.settings.delete('allow_moderator_claim');
  await applySchema(db);
  assert.equal(db.state.settings.get('default_mute_hours').SETTING_VALUE, '168');
  assert.equal(db.state.settings.get('allow_moderator_claim').SETTING_VALUE, 'true');
  assert(!ddl(db.state.calls).some(c => /SEQUENCE/.test(c.sql)));
  assert.equal(db.state.calls.filter(c => c.sql.startsWith('MERGE INTO n_moderation_settings')).length, 1);
});
test('missing sequence starts above retained rows and is never reset on retry', async () => {
  const db = schemaFixture(); db.state.sequences.delete('SEQ_2FA_RECOVERY_CODE_ID'); db.state.maxId = 57;
  await applySchema(db);
  assert(db.state.calls.some(c => /CREATE SEQUENCE seq_2fa_recovery_code_id\s+START WITH 58/.test(c.sql)));
  const before = db.state.calls.length; await applySchema(db);
  assert(!ddl(db.state.calls.slice(before)).some(c => /SEQUENCE/.test(c.sql)));
});
test('missing objects/columns are created only in apply; failed step has no success record and can resume', async () => {
  const db = schemaFixture(); db.state.tables.delete('N_USER_TWO_FACTOR_SECRETS');
  db.state.tables.get('N_MEDIA_ASSETS').columns = [];
  await assert.rejects(assertSchemaReady(db, 'two-factor'));
  assert(db.state.calls.every(c => /^SELECT\b/.test(c.sql)));
  db.state.fail = sql => sql.startsWith('ALTER TABLE n_media_assets');
  await assert.rejects(applySchema(db));
  assert(!db.state.records.has('t13-media-n_media_assets.description'));
  assert(db.state.tables.has('N_USER_TWO_FACTOR_SECRETS'));
  assert(db.state.calls.some(c => c.sql.includes('DBMS_LOCK.RELEASE')));
  db.state.fail = () => false; await applySchema(db);
  assert(db.state.records.has('t13-media-n_media_assets.description'));
});
test('same connection readiness detects later drift, without process-global ready flags', async () => {
  const db = schemaFixture(); await assertSchemaReady(db, 'media');
  db.state.tables.get('N_MEDIA_ASSETS').columns[0].CHAR_LENGTH = 999;
  await assert.rejects(assertSchemaReady(db, 'media'));
  assert(db.state.calls.every(c => /^SELECT\b/.test(c.sql)));
  const healthy = schemaFixture(); await assertSchemaReady(healthy, 'media');
});
test('parallel readiness checks coalesce per live connection and discard both success and failure', async () => {
  const connection = {}; let calls = 0; let complete;
  const check = async () => { calls++; await new Promise(resolve => { complete = resolve; }); };
  const first = coalesceReadinessCheck(connection, 'media', check);
  const second = coalesceReadinessCheck(connection, 'media', check);
  assert.equal(first, second);
  await Promise.resolve(); assert.equal(calls, 1); complete(); await first;
  await coalesceReadinessCheck(connection, 'media', async () => { calls++; });
  assert.equal(calls, 2);
  await assert.rejects(coalesceReadinessCheck(connection, 'media', async () => { throw Error('drift'); }));
  await coalesceReadinessCheck(connection, 'media', async () => { calls++; });
  await coalesceReadinessCheck({}, 'media', async () => { calls++; });
  assert.equal(calls, 4);
});
test('recorded checksum drift and incompatible column/default stop before schema changes', async () => {
  const db = schemaFixture(); await applySchema(db);
  db.state.records.set(planSchema()[0].steps[0].id, '0'.repeat(64));
  let before = db.state.calls.length; await assert.rejects(applySchema(db), /checksum drift/);
  assert.equal(ddl(db.state.calls.slice(before)).length, 0);
  const bad = schemaFixture(); bad.state.tables.get('N_GROUPS').columns[0].DATA_DEFAULT = "'unexpected'";
  await assert.rejects(applySchema(bad), /Incompatible/);
  assert(!bad.state.records.has('t13-groups-n_groups.category'));
});
test('matching moderation constraints need no DROP even with alternate names', async () => {
  const db = schemaFixture();
  for (const c of db.state.tables.get('N_MODERATION_REPORTS').constraints) if (c.CONSTRAINT_TYPE === 'C') c.CONSTRAINT_NAME = 'OLD_' + c.CONSTRAINT_NAME;
  db.state.tables.get('N_MODERATION_REPORTS').constraints.find(c => c.CONSTRAINT_NAME === 'OLD_CK_MOD_REPORTS_TARGET').SEARCH_CONDITION_VC = "(target_type IN ('group_comment','group_post','user','comment','post'))";
  await applySchema(db);
  assert(!ddl(db.state.calls).some(c => /DROP CONSTRAINT/.test(c.sql)));
});

test('Oracle implicit NOT NULL predicates coexist with target checks without accepting other restrictions', async () => {
  const db = schemaFixture();
  const table = db.state.tables.get('N_MODERATION_REPORTS');
  table.constraints.push({ CONSTRAINT_NAME: 'SYS_C_FIXTURE', CONSTRAINT_TYPE: 'C',
    SEARCH_CONDITION_VC: '"TARGET_TYPE" IS NOT NULL', STATUS: 'ENABLED', VALIDATED: 'VALIDATED',
    columns: ['TARGET_TYPE'], referencedColumns: [] });
  await applySchema(db);
  assert(!ddl(db.state.calls).some(c => /DROP CONSTRAINT/.test(c.sql)));
  table.constraints.push({ CONSTRAINT_NAME: 'CUSTOM_TARGET', CONSTRAINT_TYPE: 'C',
    SEARCH_CONDITION_VC: "target_type <> 'group_post'", STATUS: 'ENABLED', VALIDATED: 'VALIDATED',
    columns: ['TARGET_TYPE'], referencedColumns: [] });
  await assert.rejects(applySchema(db), /Incompatible/);
});
test('known legacy constraint is replaced only after validated replacement; unknown predicates refuse', async () => {
  const db = schemaFixture();
  const table = db.state.tables.get('N_MODERATION_REPORTS');
  const target = table.constraints.find(c => c.CONSTRAINT_NAME === 'CK_MOD_REPORTS_TARGET');
  target.SEARCH_CONDITION_VC = "target_type IN ('post', 'comment', 'user')"; target.columns = ['TARGET_TYPE'];
  await applySchema(db);
  const add = db.state.calls.findIndex(c => /ADD CONSTRAINT NT13_.*ENABLE VALIDATE/.test(c.sql));
  const drop = db.state.calls.findIndex(c => /DROP CONSTRAINT CK_MOD_REPORTS_TARGET/.test(c.sql));
  assert(add >= 0 && drop > add);
  assert((await checkSchema(db)).every(s => s.status === 'ready'));
  const unknown = schemaFixture(); const c = unknown.state.tables.get('N_MODERATION_REPORTS').constraints.find(c => c.CONSTRAINT_NAME === 'CK_MOD_REPORTS_TARGET');
  c.SEARCH_CONDITION_VC = "target_type = 'post'"; c.columns = ['TARGET_TYPE'];
  await assert.rejects(applySchema(unknown), /Incompatible/);
  assert(!ddl(unknown.state.calls).some(c => /DROP CONSTRAINT/.test(c.sql)));
});
test('constraint Oracle errors are not swallowed, and interruption after DROP is resumable', async () => {
  const db = schemaFixture(); const table = db.state.tables.get('N_MODERATION_REPORTS');
  const c = table.constraints.find(c => c.CONSTRAINT_NAME === 'CK_MOD_REPORTS_TARGET'); c.SEARCH_CONDITION_VC = "target_type IN ('post', 'comment', 'user')"; c.columns = ['TARGET_TYPE'];
  db.state.fail = sql => sql.includes('ADD CONSTRAINT NT13_');
  await assert.rejects(applySchema(db)); assert(table.constraints.some(c => c.CONSTRAINT_NAME === 'CK_MOD_REPORTS_TARGET'));
  assert(!db.state.records.has('t13-moderation-n_moderation_reports'));
  db.state.fail = sql => sql.includes('RENAME CONSTRAINT'); await assert.rejects(applySchema(db));
  assert(!table.constraints.some(c => c.CONSTRAINT_NAME === 'CK_MOD_REPORTS_TARGET'));
  assert(table.constraints.some(c => c.SEARCH_CONDITION_VC?.includes("'group_post'")));
  db.state.fail = () => false; await applySchema(db);
  assert(db.state.records.has('t13-moderation-n_moderation_reports'));
});
test('lock denial/driver permissions fail closed without creating a ledger or doing DDL', async () => {
  const db = schemaFixture(); db.state.lockResult = 1;
  await assert.rejects(applySchema(db), /lock/); assert.equal(ddl(db.state.calls).length, 0);
  const denied = schemaFixture(); denied.state.fail = sql => sql.includes('DBMS_LOCK.REQUEST');
  await assert.rejects(applySchema(denied)); assert.equal(ddl(denied.state.calls).length, 0);
});
test('connected CLI suppresses driver secrets and check never executes locks or DDL', async () => {
  const output = []; const env = { ORACLE_USER: 'NEKO_APP', ORACLE_PASSWORD: 'top-secret', ORACLE_HOST: 'private-host', ORACLE_PORT: '1521', ORACLE_SERVICE_NAME: 'PDB' };
  const db = schemaFixture(); let closed = 0;
  await migrateDatabase({ args: ['--check'], root: '\0invalid', env, output: x => output.push(x), loadDriver: async () => ({ getConnection: async config => { assert.equal(config.password, 'top-secret'); return { execute: db.execute, close: async () => { closed++; } }; } }) });
  assert(db.state.calls.every(c => /^SELECT\b/.test(c.sql))); assert.equal(closed, 1); assert(!output.join('').includes('top-secret'));
  await assert.rejects(migrateDatabase({ args: ['--apply'], root: '\0invalid', env, output: x => output.push(x), loadDriver: async () => { throw Error('top-secret private-host'); } }), e => !/top-secret|private-host/.test(e.message));
  assert.notEqual(normalizeExpression("x IN ('post')"), normalizeExpression("x IN ('POST')"));
});
test('business modules contain no DDL or global migration seed definitions', () => {
  for (const file of ['server/services/v2/auth.ts', 'server/services/v2/groups.ts', 'server/services/v2/moderation.ts', 'server/services/v2/users.ts', 'server/models/v2.ts']) {
    const source = readFileSync(new URL('../' + file, import.meta.url), 'utf8');
    assert(!/\b(?:CREATE TABLE|CREATE SEQUENCE|CREATE INDEX|ALTER TABLE|DROP CONSTRAINT)\b/.test(source), file);
    assert(!/MERGE INTO n_moderation_settings/.test(source), file);
    assert(source.includes('requireFeatureSchema'));
  }
});
test('driver resolution supports output-only CJS dependencies and prefers source dependencies', async t => {
  const root = mkdtempSync(join(tmpdir(), 'neko-migration-driver-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  function driver(relative, name) {
    const directory = join(root, relative, 'node_modules/oracledb');
    mkdirSync(directory, { recursive: true });
    writeFileSync(join(directory, 'index.js'), `module.exports = {name: '${name}', getConnection() { throw new Error('Test must never connect'); }};`);
  }
  driver('.output/server', 'portable-output');
  assert.equal((await loadOracleDriver(root)).default.name, 'portable-output');
  driver('', 'source-root');
  assert.equal((await loadOracleDriver(root)).default.name, 'source-root');
});
test('explicit dotenv selects an isolated configuration and process values override that file', async t => {
  const root = mkdtempSync(join(tmpdir(), 'neko-migration-env-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const credentials = user => `ORACLE_USER=${user}\nORACLE_PASSWORD=file-secret\nORACLE_HOST=isolated-db\nORACLE_PORT=1521\nORACLE_SERVICE_NAME=TESTPDB\n`;
  writeFileSync(join(root, '.env'), credentials('DEVELOPMENT_SCHEMA'));
  writeFileSync(join(root, '.env.test'), credentials('ISOLATED_SCHEMA'));
  const output = []; const db = schemaFixture(); const args = ['--check', '--dotenv', '.env.test'];
  await migrateDatabase({ args, root, env: { ORACLE_PASSWORD: 'process-secret' }, output: x => output.push(x), loadDriver: async () => ({ getConnection: async config => {
    assert.equal(config.user, 'ISOLATED_SCHEMA'); assert.equal(config.password, 'process-secret');
    assert.equal(config.connectString, 'isolated-db:1521/TESTPDB');
    return { execute: db.execute, close: async () => {} };
  } }) });
  assert.deepEqual(args, ['--check', '--dotenv', '.env.test']);
  assert(!/file-secret|process-secret|DEVELOPMENT_SCHEMA/.test(output.join('')));
});
test('dotenv argument parsing rejects unknown, missing and duplicate options before loading configuration', async () => {
  let loaded = false; const loadDriver = async () => { loaded = true; throw Error('not allowed'); };
  for (const args of [['--apply', '--check'], ['--plan', '--plan'], ['--dotenv'], ['--dotenv', '--check'], ['--dotenv', ''], ['--dotenv', 'a', '--dotenv', 'b'], ['--password', 'secret'], ['--unknown']]) {
    await assert.rejects(migrateDatabase({ args, loadDriver, output: () => {} }));
  }
  assert.equal(loaded, false);
  const unreadable = new Proxy({}, { ownKeys() { throw Error('must not read environment'); }, get() { throw Error('must not read environment'); } });
  await migrateDatabase({ args: ['--dotenv', 'missing-file', '--plan'], root: '\0invalid', env: unreadable, loadDriver, output: () => {} });
  assert.equal(loaded, false);
  await assert.rejects(migrateDatabase({ args: ['--check', '--dotenv', 'missing-file'], root: '\0invalid', env: unreadable, loadDriver, output: () => {} }), /does not exist/);
});

test('history indexes preserve owner uniqueness and the descending timestamp identity', async () => {
  const db = schemaFixture();
  const status = async name => (await checkSchema(db, 'global-search')).find(s => s.id === 'b11-' + name.toLowerCase().replaceAll('_', '-')).status;
  const recent = db.state.indexes.get('IDX_SEARCH_HISTORY_RECENT');
  recent.columns[1] = { COLUMN_NAME: 'SYS_NC00005$', DESCEND: 'DESC' };
  recent.expressions = [{ COLUMN_POSITION: 2, COLUMN_EXPRESSION: '"UPDATED_AT"' }];
  assert.equal(await status(recent.INDEX_NAME), 'ready');
  recent.expressions[0].COLUMN_EXPRESSION = '"USER_ID"';
  assert.equal(await status(recent.INDEX_NAME), 'incompatible');
  const unique = db.state.indexes.get('UK_SEARCH_HISTORY_TERM');
  unique.UNIQUENESS = 'NONUNIQUE';
  assert.equal(await status(unique.INDEX_NAME), 'incompatible');
});
