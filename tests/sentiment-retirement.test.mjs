import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { test } from 'node:test';
import { build } from 'esbuild';
import { createApp, createRouter, defineEventHandler, toNodeListener } from 'h3';
import { listenForFetch } from './helpers/loopback-listener.mjs';

const load = file => JSON.parse(readFileSync(new URL(file, import.meta.url), 'utf8'));
const contract = load('../specifications/requirements/sentiment-retirement.json');
const { cases } = load('../specifications/scenarios/sentiment-retirement.json');
const operations = [{ method: 'GET', path: 'config' }, ...contract.operations];
const root = fileURLToPath(new URL('../', import.meta.url));
const prefix = './server/api/v2/integrations/sentiment-flow/';
const imports = operations.map(({method,path}, index) =>
  "export { default as op"+index+" } from '"+prefix+path.replace(/\{([^}]+)\}/g,'[$1]')+"."+method.toLowerCase()+"';"
);
const require = createRequire(import.meta.url);
const bundle = await build({
  stdin: {
    contents: [...imports,
      "export {default as unknown} from '"+prefix+"[...path]';",
      "export {default as auth} from './server/middleware/auth';"
    ].join('\n'), resolveDir: root, loader: 'ts'
  },
  write: false, bundle: true, platform: 'node', format: 'esm',
  plugins: [{ name: 'isolate-runtime', setup(builder) {
    builder.onResolve({ filter: /.*/ }, args => {
      if (args.path === '#imports') return { path: 'runtime', namespace: 'fixture' };
      if (args.path.startsWith('~/')) return { path: path.join(root, args.path.slice(2) + '.ts') };
      if (args.path.startsWith('node:')) return { path: args.path, external: true };
      if (!args.path.startsWith('.') && !path.isAbsolute(args.path)) {
        return { path: pathToFileURL(require.resolve(args.path)).href, external: true };
      }
    });
    builder.onLoad({ filter: /.*/, namespace: 'fixture' }, () => ({
      contents: 'export const useRuntimeConfig = () => ({sentimentFlowEnabled: true, sentimentFlowBaseUrl: "http://127.0.0.1:1"});',
      loader: 'js'
    }));
  } }]
});
const handlers = await import('data:text/javascript;base64,' + Buffer.from(bundle.outputFiles[0].text).toString('base64'));

test('old sentiment paths return fixed responses without credentials, request parsing, or database access', async () => {
  const app = createApp();
  app.use(defineEventHandler(event => {
    event.context.getOracleConnection = () => { throw Error('retirement must not access Oracle'); };
  }));
  app.use(handlers.auth);
  const router = createRouter();
  for (const [index, op] of operations.entries()) {
    const name = contract.prefix+'/'+op.path.replace(/\{([^}]+)\}/g, ':$1');
    router.add(name, handlers['op'+index], op.method.toLowerCase());
  }
  // H3's test router handles exact and parameterised registrations. The app
  // fallback models Nitro's explicit catch-all for other integration paths.
  app.use(router);
  app.use(contract.prefix, handlers.unknown);
  const server = createServer(toNodeListener(app));
  const base = await listenForFetch(server);
  try {
    for (const scenario of cases) {
      const options = scenario.method === 'GET' ? {} : {body: '{', headers: {'content-type': 'application/json'}};
      const response = await fetch(base+scenario.path, {method: scenario.method, ...options});
      assert.equal(response.status, scenario.status, scenario.id);
      assert.equal(response.headers.get('cache-control'), 'private, no-store', scenario.id);
      const body = await response.json();
      assert.equal(body.code, scenario.code);
      assert.equal(body.meta, null);
      assert.deepEqual(body.data, scenario.status === 200 ? contract.config : null);
      if (scenario.status === 410) assert.equal(body.message, contract.retiredMessage);
    }
  } finally { await new Promise(resolve => server.close(resolve)); }
});
