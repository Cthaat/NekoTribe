import assert from 'node:assert/strict';
import { randomInt } from 'node:crypto';
import { createServer } from 'node:http';
import { test } from 'node:test';
import { listenForFetch } from './helpers/loopback-listener.mjs';

const close = server => new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));

test('fetch listener retries an occupied port and serves HTTP on a usable high port', async () => {
  const blocker = createServer();
  await new Promise(resolve => blocker.listen(0, '127.0.0.1', resolve));
  const server = createServer((request, response) => response.end('ok'));
  let attempts = 0;
  try {
    const origin = await listenForFetch(server, {
      choosePort: () => ++attempts === 1 ? blocker.address().port : randomInt(49152, 65536),
      maxAttempts: 64
    });
    assert.ok(attempts >= 2);
    assert.equal(new URL(origin).hostname, '127.0.0.1');
    assert.ok(Number(new URL(origin).port) >= 49152);
    const response = await fetch(origin);
    assert.equal(await response.text(), 'ok');
  } finally {
    if (server.listening) { server.closeAllConnections(); await close(server); }
    await close(blocker);
  }
});

test('fetch listener stops after the configured collision limit', async () => {
  const blocker = createServer();
  await new Promise(resolve => blocker.listen(0, '127.0.0.1', resolve));
  const server = createServer();
  let attempts = 0;
  try {
    await assert.rejects(listenForFetch(server, {
      choosePort: () => { attempts++; return blocker.address().port; },
      maxAttempts: 3
    }), error => error.code === 'EADDRINUSE');
    assert.equal(attempts, 3);
    assert.equal(server.listening, false);
  } finally { await close(blocker); }
});
