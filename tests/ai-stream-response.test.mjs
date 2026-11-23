import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { test } from 'node:test';
import { createApp, createError, toNodeListener } from 'h3';
import { readAiStream } from '../app/api/v2/ai-stream.ts';
import { defineAiGenerationHandler, generationDeltas } from '../server/services/ai/stream-response.ts';
import { listenForFetch } from './helpers/loopback-listener.mjs';

test('stream preview is provisional and only the final envelope becomes the result', async () => {
  const app = createApp();
  app.use(defineAiGenerationHandler(async event => {
    await generationDeltas(event)?.('draft');
    return { code: 200, message: 'success', data: { message_id: 'saved' }, meta: null };
  }));
  const server = createServer(toNodeListener(app));
  const origin = await listenForFetch(server);
  try {
    const response = await fetch(origin, { headers: { Accept: 'text/event-stream' } });
    assert.match(response.headers.get('content-type'), /text\/event-stream/);
    const progress = [];
    assert.deepEqual(await readAiStream(response.body, text => progress.push(text)), { message_id: 'saved' });
    assert.deepEqual(progress, ['draft']);
    const json = await (await fetch(origin)).json();
    assert.equal(json.data.message_id, 'saved');
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
});

test('an in-flight save conflict sends a terminal error', async () => {
  const app = createApp();
  app.use(defineAiGenerationHandler(async event => {
    await generationDeltas(event)?.('draft');
    throw createError({ statusCode: 409, data: { code: 40901, message: 'Conflict', data: null, meta: null } });
  }));
  const server = createServer(toNodeListener(app));
  const origin = await listenForFetch(server);
  try {
    const response = await fetch(origin, { headers: { Accept: 'text/event-stream' } });
    await assert.rejects(readAiStream(response.body, () => {}), { statusCode: 409 });
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
});
