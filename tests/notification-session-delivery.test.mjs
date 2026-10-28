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

test('periodic checks close revoked sessions and stop later room, user and broadcast sends', async () => {
  const valid = peer(), revoked = peer();
  register('periodic-valid', 42, valid, async () => true);
  register('periodic-revoked', 42, revoked, async () => false);
  module.sessionManager.joinRoom('periodic-valid', 'room');
  module.sessionManager.joinRoom('periodic-revoked', 'room');
  try {
    await module.revalidateWsSessions();
    assert.equal(valid.closed, 0);
    assert.equal(revoked.closed, 1);
    module.sendWsToRoom('room', message);
    module.sendWsToUser(42, message);
    module.sendWsToAll(message);
    assert.equal(valid.messages.length, 3);
    assert.equal(revoked.messages.length, 0);
  } finally { cleanup('periodic-valid', 'periodic-revoked'); }
});

test('a session removed while periodic verification runs is not closed again', async () => {
  const removed = peer();
  let finish;
  register('periodic-removed', 42, removed, () => new Promise(resolve => { finish = resolve; }));
  try {
    const checking = module.revalidateWsSessions();
    await new Promise(resolve => setImmediate(resolve));
    module.sessionManager.removeSession('periodic-removed');
    finish(false);
    await checking;
    assert.equal(removed.closed, 0);
  } finally { cleanup('periodic-removed'); }
});

test('periodic verification limits database checks to sixteen at a time', async () => {
  const ids = Array.from({length: 20}, (_, i) => `bounded-${i}`);
  const resolvers = [];
  ids.forEach(id => register(id, 42, peer(), () => new Promise(resolve => resolvers.push(resolve))));
  try {
    const checking = module.revalidateWsSessions();
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(resolvers.length, 16);
    resolvers.splice(0).forEach(resolve => resolve(true));
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(resolvers.length, 4);
    resolvers.splice(0).forEach(resolve => resolve(true));
    await checking;
  } finally { cleanup(...ids); }
});

test('idle cleanup closes the socket instead of leaving an unmanaged connection', () => {
  const idle = peer();
  register('idle', 42, idle, async () => true);
  const session = module.sessionManager.getSession('idle');
  session.lastActivity = Date.now() - 100;
  try {
    module.sessionManager.cleanupInactiveSessions(50);
    assert.equal(idle.closed, 1);
    assert.equal(module.sessionManager.getSession('idle'), undefined);
  } finally { cleanup('idle'); }
});
