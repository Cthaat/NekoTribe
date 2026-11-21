import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import vm from 'node:vm';
import ts from 'typescript';

const source = readFileSync(new URL('../server/services/v2/auth.ts', import.meta.url), 'utf8');
const { outputText } = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 }
});

function fixture({ claimed = 1, failure, duplicate = false } = {}) {
  const trace = [];
  const fail = status => () => { throw Object.assign(new Error(String(status)), { status }); };
  const utils = {
    v2Body: event => event.body,
    v2RequiredString: (body, field) => body[field],
    v2String: v => v ?? '',
    v2Number: v => Number(v ?? 0),
    v2BadRequest: fail(400),
    v2Conflict: fail(409),
    v2Unprocessable: fail(422),
    v2ServerError: fail(500),
    v2Ok: data => data,
    v2One: async (_, sql) => {
      if (sql.includes('verified_at IS NOT NULL')) {
        trace.push('precheck');
        return { VERIFIED_AT: 'valid' };
      }
      if (sql.includes('COUNT(*)')) {
        trace.push('duplicates');
        return { TOTAL: duplicate && trace.includes('rollback') ? 1 : 0 };
      }
      return { ID: 7 };
    },
    v2Execute: async (_, sql, binds, autoCommit) => {
      assert.equal(autoCommit, false);
      if (sql.startsWith('UPDATE')) {
        assert.match(sql, /SET expires_at = created_at/);
        assert.match(sql, /otp_type = 'register'/);
        assert.match(sql, /expires_at > CURRENT_TIMESTAMP AND expires_at > created_at AND verified_at IS NOT NULL/);
        assert.equal(binds.account, 'example@example.test');
        assert.equal(binds.verification_id, 'otp_fixture');
        trace.push('claim');
        return claimed;
      }
      trace.push('insert');
      if (failure === 'duplicate') throw Object.assign(new Error('db failure'), { errorNum: 1 });
      if (failure === 'insert') throw new Error('db failure');
      return 1;
    }
  };
  const deps = {
    '~/server/utils/v2': utils,
    '../../../shared/utils/account-input': { validNewEmail: () => true, validRegistrationName: () => true },
    '~/server/models/v2': { v2RequireSelfUser: async () => { trace.push('profile'); return { user_id: 7 }; } },
    bcrypt: { default: { hash: async () => { trace.push('hash'); return 'synthetic'; } } }
  };
  const exports = {};
  vm.runInNewContext(outputText, { exports, require: name => deps[name] ?? {} });
  const connection = {
    commit: async () => { trace.push('commit'); },
    rollback: async () => { trace.push('rollback'); }
  };
  const event = {
    body: {
      email: 'example@example.test', username: 'fixture', display_name: 'Fixture',
      password: 'synthetic-password', confirm_password: 'synthetic-password',
      agree_to_terms: true, verification_id: 'otp_fixture'
    }
  };
  return { register: () => exports.v2Register(event, connection), trace };
}

test('registration commits the OTP claim and user before returning the profile', async () => {
  const { register, trace } = fixture();
  assert.equal((await register()).user.user_id, 7);
  assert.deepEqual(trace, ['precheck', 'duplicates', 'hash', 'claim', 'insert', 'commit', 'profile']);
});

test('expired claims and failed inserts roll back without reading the profile', async () => {
  const lost = fixture({ claimed: 0 });
  await assert.rejects(lost.register(), { status: 422 });
  assert.deepEqual(lost.trace.slice(-2), ['claim', 'rollback']);
  const failed = fixture({ failure: 'insert' });
  await assert.rejects(failed.register(), /db failure/);
  assert.deepEqual(failed.trace.slice(-3), ['claim', 'insert', 'rollback']);
  const conflict = fixture({ failure: 'duplicate', duplicate: true });
  await assert.rejects(conflict.register(), { status: 409 });
  assert.deepEqual(conflict.trace.slice(-3), ['insert', 'rollback', 'duplicates']);
});

test('the claim cannot be repeated and rollback restores the eligibility', t => {
  const db = new DatabaseSync(':memory:');
  t.after(() => db.close());
  db.exec(`
    CREATE TABLE n_auth_otp_events(account, otp_type, verification_id, expires_at, created_at, verified_at);
    INSERT INTO n_auth_otp_events VALUES
      ('example@example.test','register','otp_fixture','2099-01-02','2020-01-01','2020-01-01'),
      ('example@example.test','password_reset','wrong_type','2099-01-02','2020-01-01','2020-01-01'),
      ('example@example.test','register','unverified','2099-01-02','2020-01-01',NULL),
      ('example@example.test','register','expired','2020-01-02','2020-01-01','2020-01-01');
  `);
  const match = source.match(/const registrationOtpMatchSql = `([\s\S]+?)`;/)[1];
  const stmt = db.prepare('UPDATE n_auth_otp_events SET expires_at = created_at ' + match);
  const claim = (verification_id = 'otp_fixture', account = 'example@example.test') =>
    stmt.run({ account, verification_id }).changes;
  for (const id of ['wrong_type', 'unverified', 'expired']) assert.equal(claim(id), 0);
  assert.equal(claim('otp_fixture', 'other@example.test'), 0);
  db.exec('BEGIN');
  assert.equal(claim(), 1);
  db.exec('ROLLBACK');
  assert.equal(claim(), 1);
  assert.equal(claim(), 0);
});
