import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { existsSync, mkdtempSync, readFileSync, rmdirSync } from 'node:fs';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';
import Redis from 'ioredis';
import { createError } from 'h3';
import ts from 'typescript';
import vm from 'node:vm';
import * as crypto from 'node:crypto';

const read = path => readFileSync(new URL(path, import.meta.url), 'utf8');
const source = read('../server/utils/otp-send-limit.ts');
const sql = source.match(/const otpSendLimitLua = `([\s\S]+?)`;/)[1];
const { outputText } = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 }
});
const api = {};
vm.runInNewContext(outputText, {
  exports: api, require: () => crypto, setTimeout, clearTimeout
});
const { otpSendKeys, reserveOtpSend } = api;

test('OTP send limiter uses identical Lua and private account keys', async () => {
  const go = '../../go/internal/server/otp_send_limit.go';
  const rust = '../../rust/src/auth/otp_send_limit.rs';
  if ([go, rust].every(path => existsSync(new URL(path, import.meta.url)))) {
    assert.equal(read(go).match(/const otpSendLimitLua = `([\s\S]+?)`/)[1], sql);
    assert.equal(read(rust).match(/const OTP_SEND_LIMIT_LUA:\s*&str\s*=\s*"([\s\S]+?)";/)[1], sql);
  }
  const keys = Array.from(otpSendKeys('Example@Example.Test'));
  assert.deepEqual(keys, Array.from(otpSendKeys('example@example.test')));
  assert.equal(keys[0], 'neko:auth:otp-send:v1:{2ecd29ed8b5e3975d29c00aa4d3a2553bfc46f2391fc39355c23719f8c5314a9}:cooldown');
  assert.equal(keys[1], keys[0].replace(/cooldown$/, 'window'));
  const redis = { eval: async (script, count, ...actual) => {
    assert.equal(script, sql);
    assert.equal(count, 2);
    assert.deepEqual(actual, keys);
    return 42;
  } };
  assert.equal(await reserveOtpSend(redis, 'example@example.test'), 42);
  await assert.rejects(reserveOtpSend(undefined, 'example@example.test'), /unavailable/);
  await assert.rejects(reserveOtpSend({ eval: async () => '0' }, 'example@example.test'), /unavailable/);
});

test('Nuxt rejects throttled or unavailable OTP sends before using Oracle', async () => {
  const auth = ts.transpileModule(read('../server/services/v2/auth.ts'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 }
  }).outputText;
  const deps = {
    h3: { createError, setResponseHeader: (event, name, value) => { event.headers[name] = String(value); } },
    '~/server/utils/otp-send-limit': { reserveOtpSend },
    '../../../shared/utils/account-input': { validNewEmail: () => true },
    '~/server/utils/v2': {
      v2Body: event => event.body,
      v2String: (value, fallback) => value ?? fallback,
      v2RequiredString: (body, key) => body[key],
      v2Throw: (statusCode, message) => { throw createError({ statusCode, message }); },
      v2One: () => { throw new Error('Unexpected Oracle read'); },
      v2Execute: () => { throw new Error('Unexpected Oracle write'); }
    }
  };
  const exports = {};
  vm.runInNewContext(auth, { exports, require: name => deps[name] ?? {} });
  const event = { body: { account: 'fixture@example.test', type: 'register' }, context: {}, headers: {} };
  await assert.rejects(exports.v2CreateOtp(event, {}), { statusCode: 503 });
  event.context.redis = { eval: async () => 42 };
  await assert.rejects(exports.v2CreateOtp(event, {}), { statusCode: 429 });
  assert.equal(event.headers['Retry-After'], '42');
});

const binary = process.env.NEKO_OTP_TEST_REDIS_BIN;
test('isolated Redis enforces shared send and code comparison budgets', {
  skip: !binary, timeout: 10000
}, async t => {
  const probe = createServer().listen(0, '127.0.0.1');
  await once(probe, 'listening');
  const { port } = probe.address();
  await new Promise(resolve => probe.close(resolve));
  const dir = mkdtempSync(join(tmpdir(), 'otp-limit-test-'));
  const child = spawn(binary, [
    '--bind', '127.0.0.1', '--port', String(port), '--save', '',
    '--appendonly', 'no', '--dir', dir
  ], { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
  let output = '';
  for (const stream of [child.stdout, child.stderr]) {
    stream.on('data', chunk => { output = (output + chunk).slice(-2000); });
  }
  const gone = new Promise(resolve => {
    child.once('exit', resolve);
    child.once('error', resolve);
  });
  const redis = new Redis({ host: '127.0.0.1', port, lazyConnect: true, connectTimeout: 250, retryStrategy: () => null });
  redis.on('error', () => {});
  t.after(async () => {
    redis.disconnect();
    if (child.pid && child.exitCode === null) child.kill();
    await gone;
    rmdirSync(dir);
  });
  for (let attempt = 0; ; attempt++) {
    try {
      await redis.connect();
      break;
    } catch (error) {
      if (attempt >= 15 || child.exitCode !== null) throw new Error(output || String(error));
      await delay(100);
    }
  }
  const info = await redis.info('server');
  assert.equal(Number(info.match(/^process_id:(\d+)/m)?.[1]), child.pid);
  const account = 'fixture@example.test';
  const [cooldown, window] = otpSendKeys(account);
  const concurrent = await Promise.all(Array.from({ length: 8 }, () => reserveOtpSend(redis, account)));
  assert.equal(concurrent.filter(result => result === 0).length, 1);
  assert.ok(concurrent.filter(result => result !== 0).every(result => result >= 1 && result <= 60));
  for (let count = 2; count <= 5; count++) {
    await redis.del(cooldown);
    assert.equal(await reserveOtpSend(redis, account), 0);
    assert.equal(await redis.get(window), String(count));
  }
  assert.ok(await reserveOtpSend(redis, account) > 60);
  assert.equal(await reserveOtpSend(redis, 'isolated@example.test'), 0);

  const attemptSources = [
    ['../server/utils/otp-attempt-limit.ts', /const otpAttemptLimitLua = `([\s\S]+?)`;/],
    ['../../go/internal/server/otp_attempt_limit.go', /const otpAttemptLimitLua = `([\s\S]+?)`/],
    ['../../rust/src/auth/otp_attempt_limit.rs', /const OTP_ATTEMPT_LIMIT_LUA:\s*&str\s*=\s*"([\s\S]+?)";/]
  ].filter(([path]) => existsSync(new URL(path, import.meta.url)))
    .map(([path, pattern]) => read(path).match(pattern)[1]);
  assert.equal(new Set(attemptSources).size, 1);
  const key = 'neko:auth:otp-attempt:v1:' + crypto.createHash('sha256').update('otp_fixture').digest('hex');
  const attempts = await Promise.all(Array.from({ length: 18 }, (_, i) =>
    redis.eval(attemptSources[i % attemptSources.length], 1, key)
  ));
  assert.equal(attempts.filter(result => result === 1).length, 5);
  assert.equal(attempts.filter(result => result === 0).length, 13);
  assert.equal(await redis.get(key), '5');
  assert.ok(await redis.pttl(key) > 300_000);
  assert.equal(await redis.eval(attemptSources[0], 1, key + ':other'), 1);
  await redis.set(key, '5');
  await assert.rejects(redis.eval(attemptSources[0], 1, key), /invalid OTP attempt limit state/);
});
