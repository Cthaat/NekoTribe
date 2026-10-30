import assert from 'node:assert/strict';
import { test } from 'node:test';
import { IncomingMessage, ServerResponse } from 'node:http';
import { Socket } from 'node:net';
import { fileURLToPath } from 'node:url';
import { createEvent } from 'h3';
import { build } from 'esbuild';

const root = fileURLToPath(new URL('../', import.meta.url));
const compiled = await build({
  stdin: { contents: `export {readApiResponseCache} from './server/utils/api-cache';`, resolveDir: root, loader: 'ts' },
  bundle: true, write: false, platform: 'node', format: 'esm',
  plugins: [{ name: 'cache-boundaries', setup(builder) {
    builder.onResolve({filter: /^\.\/logging$/}, () => ({path:'logging', namespace:'stub'}));
    builder.onResolve({filter: /^\.\/cache-mode$/}, () => ({path:'mode', namespace:'stub'}));
    builder.onLoad({filter: /.*/, namespace:'stub'}, args => ({loader:'js', contents: args.path === 'mode'
      ? `export const singleBackendCacheEnabled=true, cacheProcessEpoch='test';`
      : `export const getRequestLogContext=()=>null,logInfo=()=>{},logWarn=()=>{},serializeLogError=()=>({});`}));
  }}]
});
const { readApiResponseCache } = await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);

test('AI conversation reads bypass response cache even in single-backend mode', async () => {
  for (const path of ['/api/v2/ai/conversations', '/api/v2/ai/conversations/a/messages']) {
    const socket = new Socket(), request = new IncomingMessage(socket);
    request.url = path; request.method = 'GET';
    const response = new ServerResponse(request), event = createEvent(request, response);
    let calls = 0;
    event.context.auth = { userId: 42 };
    event.context.redis = { async mget() { calls++; return []; }, async get() { calls++; return null; } };
    try {
      assert.deepEqual(await readApiResponseCache(event, 'v2'), { status: 'bypass', reason: 'not_cacheable' });
      assert.equal(calls, 0);
    } finally { response.destroy(); socket.destroy(); }
  }
});
