// Real Nuxt middleware and JWT verifier, isolated Oracle update/clock only.
// No HTTP server, network, database, environment file, or real credentials.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { IncomingMessage, ServerResponse } from 'node:http';
import { Socket } from 'node:net';
import { test } from 'node:test';
import { createEvent } from 'h3';
import { build } from 'esbuild';
import jwt from 'jsonwebtoken';

const require = createRequire(import.meta.url);
const root = fileURLToPath(new URL('../', import.meta.url));
const vectors = JSON.parse(readFileSync(new URL('../specifications/scenarios/auth-tokens.json', import.meta.url)));
const compiled = await build({
  entryPoints: [fileURLToPath(new URL('../server/middleware/auth.ts', import.meta.url))],
  bundle: true, write: false, platform: 'node', format: 'esm',
  plugins: [{ name: 'token-vector-clock', setup(builder) {
    builder.onResolve({ filter: /.*/ }, args => {
      if (args.path.startsWith('file:')) return { path: args.path, external: true };
      if (args.path === '#imports' || args.path === 'jsonwebtoken') return { path: args.path, namespace: 'vector-stub' };
      if (!args.path.startsWith('.') && !args.path.startsWith(root)) return { path: pathToFileURL(require.resolve(args.path)).href, external: true };
    });
    builder.onLoad({ filter: /.*/, namespace: 'vector-stub' }, args => ({
      contents: args.path === '#imports'
        ? `export const useRuntimeConfig = () => ({accessSecret:${JSON.stringify(vectors.keys.access)}});`
        : `import jwt from ${JSON.stringify(pathToFileURL(require.resolve('jsonwebtoken')).href)};
           export default {verify(token, key){return jwt.verify(token,key,{clockTimestamp:${vectors.now}});}};`,
      loader: 'js'
    }));
  } }]
});
const { default: middleware } = await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);

assert.equal(vectors.cases.length, 25);
for (const vector of vectors.cases) {
  test(`Nuxt token reference: ${vector.id}`, async () => {
    if (vector.type === 'refresh') {
      const payload = jwt.verify(vector.token, vectors.keys.refresh, { clockTimestamp: vectors.now });
      assert.equal(payload.type, 'refresh'); assert.equal(payload.userId, vector.expectedUserId);
      return;
    }
    const socket = new Socket();
    const request = new IncomingMessage(socket);
    request.url = '/api/v2/users/me'; request.method = 'GET';
    request.headers = { authorization: `Bearer ${vector.token}` };
    const response = new ServerResponse(request);
    const event = createEvent(request, response);
    let updates = 0;
    event.context.getOracleConnection = async () => ({
      async execute(sql, binds) {
        assert(sql.includes('UPDATE n_auth_sessions'));
        assert.equal(binds.userId, vector.expectedUserId);
        updates++; return { rowsAffected: 1 };
      },
      async close() {}
    });
    try {
      if (vector.expectedValid) {
        await middleware(event);
        assert.equal(event.context.auth.userId, vector.expectedUserId);
        assert.equal(updates, 1);
      } else {
        await assert.rejects(() => middleware(event), error => error.statusCode === 401);
        assert.equal(updates, 0);
      }
    } finally { response.destroy(); socket.destroy(); }
  });
}
