import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import { build } from 'esbuild';

const root = fileURLToPath(new URL('../', import.meta.url));
const require = createRequire(import.meta.url);
const fakePassword = 'fake-oracle-password-DO-NOT-LOG';
const fakeToken = 'fake-token-DO-NOT-LOG';
const fakeAddress = 'oracle://fake-user:fake-oracle-password-DO-NOT-LOG@fake-db.example:1521/FAKE';
const stubs = {
  '#imports': 'export const useRuntimeConfig = () => globalThis.__oraclePoolTestConfig;',
  oracledb: 'export default { createPool: async () => { throw globalThis.__oraclePoolTestError; } };',
  '~/server/utils/oracle-query-cache': 'export const clearOracleQueryCacheSource = value => value;'
};

const compiled = await build({
  entryPoints: [path.join(root, 'server/utils/oracle.ts')],
  bundle: true, write: false, platform: 'node', format: 'esm',
  plugins: [{ name: 'oracle-pool-boundaries', setup(builder) {
    builder.onResolve({ filter: /.*/ }, args => {
      if (Object.hasOwn(stubs, args.path)) return { path: args.path, namespace: 'test-stub' };
      if (args.path.startsWith('~/')) return { path: path.join(root, `${args.path.slice(2)}.ts`) };
      if (args.path.startsWith('node:')) return { path: args.path, external: true };
      if (!args.path.startsWith('.') && !path.isAbsolute(args.path)) {
        return { path: pathToFileURL(require.resolve(args.path)).href, external: true };
      }
    });
    builder.onLoad({ filter: /.*/, namespace: 'test-stub' }, args => ({ contents: stubs[args.path], loader: 'js' }));
  }}]
});
const { initOraclePool } = await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);

test('pool failure logs only a safe category and rethrows the original error', async () => {
  globalThis.__oraclePoolTestConfig = {
    oracleHost: 'fake-db.example', oraclePort: 1521, oracleServiceName: 'FAKE',
    oracleUser: 'fake-user', oraclePassword: fakePassword
  };
  const failure = new Error(`synthetic-driver-failure ${fakePassword} ${fakeToken} ${fakeAddress}`);
  failure.stack = `synthetic-private-stack ${fakePassword} ${fakeToken} ${fakeAddress}`;
  failure.code = 'ORA-01017';
  globalThis.__oraclePoolTestError = failure;
  const logs = [];
  const originalInfo = console.info;
  const originalError = console.error;
  console.info = (...args) => logs.push(args);
  console.error = (...args) => logs.push(args);
  try {
    await assert.rejects(initOraclePool(), error => error === failure);
    const rendered = JSON.stringify(logs);
    for (const secret of [fakePassword, fakeToken, fakeAddress, 'synthetic-driver-failure', 'synthetic-private-stack']) {
      assert(!rendered.includes(secret), `pool log exposed ${secret}`);
    }
    assert.match(rendered, /pool:create:error/);
    assert.match(rendered, /ORA-01017/);
  } finally {
    console.info = originalInfo;
    console.error = originalError;
    delete globalThis.__oraclePoolTestConfig;
    delete globalThis.__oraclePoolTestError;
  }
});

test('invalid or unreadable driver codes cannot leak data or replace the original error', async () => {
  globalThis.__oraclePoolTestConfig = { oracleHost: 'fake-db.example', oraclePort: 1521,
    oracleServiceName: 'FAKE', oracleUser: 'fake-user', oraclePassword: fakePassword };
  const logs = [];
  const originalInfo = console.info;
  const originalError = console.error;
  console.info = (...args) => logs.push(args);
  console.error = (...args) => logs.push(args);
  try {
    for (const unreadable of [false, true]) {
      const failure = new Error(`driver failure ${fakeToken}`);
      Object.defineProperty(failure, 'code', unreadable
        ? { get() { throw new Error('private-code-getter'); } }
        : { value: fakeToken });
      globalThis.__oraclePoolTestError = failure;
      await assert.rejects(initOraclePool(), error => error === failure);
    }
    const rendered = JSON.stringify(logs);
    assert(!rendered.includes(fakeToken));
    assert(!rendered.includes('private-code-getter'));
    assert.match(rendered, /oracle_pool_initialization_failed/);
    assert.match(rendered, /unknown/);
  } finally {
    console.info = originalInfo;
    console.error = originalError;
    delete globalThis.__oraclePoolTestConfig;
    delete globalThis.__oraclePoolTestError;
  }
});
