import assert from 'node:assert/strict';
import {test} from 'node:test';
import {fileURLToPath} from 'node:url';
import {build} from 'esbuild';

// The session manager's diagnostic output is irrelevant to these assertions.
console.log = () => {};

const root = fileURLToPath(new URL('../', import.meta.url));
const bundled = await build({
  entryPoints: [fileURLToPath(new URL('../server/utils/wsSession.ts', import.meta.url))],
  absWorkingDir: root, bundle: true, write: false, platform: 'node', format: 'esm'
});
const module = await import(`data:text/javascript;base64,${Buffer.from(bundled.outputFiles[0].text).toString('base64')}`);

const message = {type: 'notification_created', data: {id: 7}, timestamp: 100};
function peer() {
  return {messages: [], closed: 0, send(value) { this.messages.push(JSON.parse(value)); }, close() { this.closed++; }};
}
function register(id, userId, target, authorize) {
  module.sessionManager.addSession(id, target, {userId, sessionId: id, jti: `jti-${id}`, type: 'access'}, authorize);
}
function cleanup(...ids) { ids.forEach(id => module.sessionManager.removeSession(id)); }

test('notification delivery validates each matching session and closes revoked ones', async () => {
  const valid = peer(), revoked = peer(), other = peer();
  let checks = 0;
  register('valid', 42, valid, async () => { checks++; return true; });
  register('revoked', 42, revoked, async () => false);
  register('other', 9, other, async () => { throw new Error('wrong user checked'); });
  try {
    await module.sendWsNotificationToUser(42, message);
    assert.deepEqual(valid.messages, [message]);
    assert.deepEqual(revoked.messages, []);
    assert.equal(revoked.closed, 1);
    assert.deepEqual(other.messages, []);
    assert.equal(checks, 1);
  } finally { cleanup('valid', 'revoked', 'other'); }
});

test('failed verification and removal while verification is pending do not leak events', async () => {
  const failed = peer(), removed = peer();
  let finish;
  register('failed', 42, failed, async () => { throw new Error('private database error'); });
  register('removed', 42, removed, () => new Promise(resolve => { finish = resolve; }));
  try {
    const sending = module.sendWsNotificationToUser(42, message);
    await new Promise(resolve => setImmediate(resolve));
    module.sessionManager.removeSession('removed');
    finish(true);
    await sending;
    assert.deepEqual(failed.messages, []);
    assert.equal(failed.closed, 1);
    assert.deepEqual(removed.messages, []);
  } finally { cleanup('failed', 'removed'); }
});

test('a slow session is closed when its bounded notification queue fills', async () => {
  const slow = peer();
  let finish;
  register('slow', 42, slow, () => new Promise(resolve => { finish = resolve; }));
  try {
    const deliveries = Array.from({length: 17}, () => module.sendWsNotificationToUser(42, message));
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(slow.closed, 1);
    if (finish) finish(true);
    await Promise.all(deliveries);
    assert.deepEqual(slow.messages, []);
  } finally { cleanup('slow'); }
});

test('a stalled session check eventually closes the connection', async () => {
  const stalled = peer();
  register('stalled', 42, stalled, () => new Promise(() => {}));
  try {
    await Promise.race([
      module.sendWsNotificationToUser(42, message),
      new Promise((_, reject) => setTimeout(() => reject(new Error('verification did not time out')), 2_500))
    ]);
    assert.equal(stalled.closed, 1);
    assert.deepEqual(stalled.messages, []);
  } finally { cleanup('stalled'); }
});
