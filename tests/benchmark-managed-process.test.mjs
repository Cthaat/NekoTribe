import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createServer } from 'node:http';
import { test } from 'node:test';
import { benchmarkProcess } from '../scripts/benchmark/managed-process.mjs';
import { login, requestJson } from '../scripts/benchmark/http.mjs';

const listener = `
  const { createServer } = require('node:http');
  createServer((request, response) => {
    response.setHeader('Content-Type', 'application/json');
    const body = request.url === '/api/ready' ? { ready: true } : {
      code: 200,
      data: {
        user: { user_id: 17 },
        tokens: { session_id: 'fixture-session', access_token: 'fixture-access', refresh_token: 'fixture-refresh' }
      }
    };
    response.end(JSON.stringify(body));
  }).listen(Number(process.env.BENCH_FIXTURE_PORT), '127.0.0.1');
`;

const listen = async server => {
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return server.address().port;
};
const settings = { startupTimeoutMs: 3000, timeoutMs: 1500 };

test('managed benchmark samples an actual child, loads a fixture session and closes the child', { timeout: 15000 }, async () => {
  const reservation = createServer();
  const port = await listen(reservation);
  await new Promise(resolve => reservation.close(resolve));
  const target = {
    baseUrl: `http://127.0.0.1:${port}`,
    account: 'fixture-account',
    password: 'fixture-password',
    launch: {
      command: process.execPath, args: ['-e', listener], cwd: process.cwd(),
      env: { BENCH_FIXTURE_PORT: String(port) },
    },
  };
  const result = await benchmarkProcess(target, settings, async activeTarget => {
    const session = await login(activeTarget, settings.timeoutMs);
    return { fixture: { userId: session.userId } };
  });
  assert.equal(result.error, undefined);
  assert(result.startupMs > 0);
  assert(result.peakRssMiB > 0);
  assert.deepEqual(result.workloads, { fixture: { userId: 17 } });
  await assert.rejects(requestJson(target, { path: '/api/ready', timeoutMs: 500 }), /Backend request failed/);
});

test('a preexisting HTTP responder is not used for managed benchmarks', async t => {
  const server = createServer((_request, response) => response.end('already serving'));
  const port = await listen(server);
  t.after(() => new Promise(resolve => {
    server.close(resolve);
    server.closeAllConnections();
  }));
  const result = await benchmarkProcess({
    baseUrl: `http://127.0.0.1:${port}`,
    launch: { command: 'ignored', args: [], cwd: process.cwd(), env: {} },
  }, settings, () => assert.fail('Unexpected benchmark on a preexisting responder'));
  assert.equal(result.error, 'Target URL already has a responder.');
  assert.equal(result.startupMs, null);
});
