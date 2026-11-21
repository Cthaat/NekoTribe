import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, copyFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { resolveRuntimeEnvironment, sessionLifetimes } from '../scripts/runtime-env.mjs';

test('session seconds are checked before use, with prefixed values taking precedence', () => {
  assert.deepEqual(sessionLifetimes({}),{accessSeconds:900,refreshSeconds:2592000});
  assert.deepEqual(sessionLifetimes({
    ACCESS_EXPIRES_IN:'900', NUXT_ACCESS_EXPIRES_IN:' +030 ',
    REFRESH_EXPIRES_IN:'60',
  }),{accessSeconds:30,refreshSeconds:60});
  assert.deepEqual(sessionLifetimes({
    ACCESS_EXPIRES_IN:'2147483646',REFRESH_EXPIRES_IN:'2147483647',
  }),{accessSeconds:2147483646,refreshSeconds:2147483647});
  for (const invalid of ['', '0', '-1', '1e2', '0x20', '1.5', '2147483648']) {
    assert.throws(()=>sessionLifetimes({ACCESS_EXPIRES_IN:'30',NUXT_ACCESS_EXPIRES_IN:invalid}),/Invalid token lifetime/);
  }
  assert.throws(()=>sessionLifetimes({ACCESS_EXPIRES_IN:'30',REFRESH_EXPIRES_IN:'30'}),/Invalid token lifetime/);
});

test('legacy values map at startup without mutating the caller', () => {
  const input = { ORACLE_HOST: 'remote-db', REDIS_PORT: '6388' };
  const env = resolveRuntimeEnvironment(input, 'start');
  assert.equal(env.NUXT_ORACLE_HOST, 'remote-db');
  assert.equal(env.NUXT_REDIS_PORT, '6388');
  assert.equal(env.NODE_ENV, 'production');
  assert.equal(input.NUXT_ORACLE_HOST, undefined);
});

test('canonical values win consistently, including explicit empty settings', () => {
  const env = resolveRuntimeEnvironment({
    ORACLE_HOST: 'old', NUXT_ORACLE_HOST: 'new',
    REDIS_PASSWORD: 'old-password', NUXT_REDIS_PASSWORD: '',
    NODE_ENV: 'production'
  }, 'dev');
  assert.equal(env.ORACLE_HOST, 'new');
  assert.equal(env.REDIS_PASSWORD, '');
  assert.equal(env.NUXT_NODE_ENV, 'development');
});

test('old sentiment settings do not configure the Nuxt runtime', () => {
  const env = resolveRuntimeEnvironment({
    SENTIMENTFLOW_ENABLED: 'true',
    SENTIMENTFLOW_BASE_URL: 'http://legacy.example.test',
    SENTIMENTFLOW_TIMEOUT_MS: '6000'
  }, 'start');
  assert.equal(env.NUXT_SENTIMENT_FLOW_ENABLED, undefined);
  assert.equal(env.NUXT_PUBLIC_SENTIMENT_FLOW_ENABLED, undefined);
  assert.equal(env.NUXT_SENTIMENT_FLOW_BASE_URL, undefined);
  assert.equal(env.NUXT_SENTIMENT_FLOW_TIMEOUT_MS, undefined);
});

test('portable production launcher reads destination dotenv and respects process overrides', async () => {
  const root = await mkdtemp(join(tmpdir(), 'nekotribe-runtime-'));
  try {
    await mkdir(join(root, 'scripts'));
    await mkdir(join(root, '.output/server'), { recursive: true });
    for (const name of ['run-nuxt.mjs', 'runtime-env.mjs']) {
      await copyFile(new URL(`../scripts/${name}`, import.meta.url), join(root, 'scripts', name));
    }
    await writeFile(join(root, '.env'), 'ORACLE_HOST=destination-db\nREDIS_PORT=6388\nPORT=31001\n');
    await writeFile(join(root, '.output/server/index.mjs'),
      'console.log(JSON.stringify({db:process.env.NUXT_ORACLE_HOST,redis:process.env.NUXT_REDIS_PORT,port:process.env.PORT,mode:process.env.NODE_ENV}))');
    const env = { ...process.env, ORACLE_HOST: 'process-db' };
    for (const key of ['NUXT_ORACLE_HOST', 'NUXT_REDIS_PORT', 'REDIS_PORT', 'PORT']) delete env[key];
    const result = spawnSync(process.execPath, [join(root, 'scripts/run-nuxt.mjs'), 'start'], {
      cwd: tmpdir(), env, encoding: 'utf8'
    });
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(JSON.parse(result.stdout), {
      db: 'process-db', redis: '6388', port: '31001', mode: 'production'
    });
    const missing = spawnSync(process.execPath, [join(root, 'scripts/run-nuxt.mjs'), 'start', '--dotenv', 'missing.env'], { encoding: 'utf8' });
    assert.notEqual(missing.status, 0);
    assert.match(missing.stderr, /environment file does not exist/);
    const badLifetime = spawnSync(process.execPath, [join(root, 'scripts/run-nuxt.mjs'), 'start'], {
      env:{...env,NUXT_ACCESS_EXPIRES_IN:'60',NUXT_REFRESH_EXPIRES_IN:'60'},
      encoding:'utf8',
    });
    assert.equal(badLifetime.status,1);
    assert.equal(badLifetime.stdout,'');
    assert.match(badLifetime.stderr,/Invalid token lifetime/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
