import assert from 'node:assert/strict';
import { test } from 'node:test';
import { build } from 'esbuild';

const compiled = await build({
  entryPoints: ['server/utils/redis-config.ts'],
  bundle: true,
  write: false,
  format: 'esm',
  platform: 'node',
  plugins: [{
    name: 'runtime-config-stub',
    setup(builder) {
      builder.onResolve({ filter: /^#imports$/ }, () => ({ path: 'imports', namespace: 'stub' }));
      builder.onLoad({ filter: /.*/, namespace: 'stub' }, () => ({
        contents: 'export const useRuntimeConfig = () => ({})',
      }));
    },
  }],
});
const { resolveRedisOptions } = await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);
const keys = ['URL', 'HOST', 'PORT', 'DB', 'PASSWORD'].flatMap(key => [`REDIS_${key}`, `NUXT_REDIS_${key}`]);

function withRedisEnv(overrides, check) {
  const previous = Object.fromEntries(keys.map(key => [key, process.env[key]]));
  try {
    for (const key of keys) delete process.env[key];
    Object.assign(process.env, overrides);
    check();
  } finally {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
}

test('rediss follows the final host and keeps URL values when a prefixed override is empty', () => {
  withRedisEnv({
    NUXT_REDIS_URL: 'rediss://service:sample%40value@original.test:6380/3',
    REDIS_HOST: 'actual.test',
    REDIS_PORT: '6381',
    NUXT_REDIS_PORT: '',
    REDIS_DB: '4',
    NUXT_REDIS_DB: '',
  }, () => {
    const { host, port, db, username, password, tls } = resolveRedisOptions();
    assert.equal(host, 'actual.test');
    assert.equal(port, 6380);
    assert.equal(db, 3);
    assert.equal(username, 'service');
    assert.equal(password, 'sample@value');
    assert.deepEqual(tls, { minVersion: 'TLSv1.2', servername: 'actual.test' });
  });
});

test('bare addresses preserve plaintext and malformed secure settings fail with a fixed message', () => {
  withRedisEnv({ REDIS_URL: '[::1]:6379/0' }, () => {
    const { host, tls } = resolveRedisOptions();
    assert.equal(host, '::1');
    assert.equal(tls, undefined);
  });
  for (const overrides of [
    { REDIS_URL: 'https://private.test' },
    { REDIS_URL: 'rediss://private.test:0' },
    { REDIS_URL: 'rediss://private.test/3', REDIS_DB: '8private' },
  ]) {
    withRedisEnv(overrides, () => {
      assert.throws(resolveRedisOptions, { message: 'Invalid Redis configuration' });
    });
  }
});

test('a split password override is literal even when it contains URL escapes', () => {
  withRedisEnv({
    REDIS_URL: 'rediss://service:old%40secret@redis.example.test/3',
    REDIS_PASSWORD: 'new@secret:%2F/%25',
  }, () => {
    const { username, password } = resolveRedisOptions();
    assert.equal(username, 'service');
    assert.equal(password, 'new@secret:%2F/%25');
  });
});
