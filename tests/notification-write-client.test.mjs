import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';

const compiled = await build({
  entryPoints: ['app/api/v2/notifications.ts'],
  absWorkingDir: fileURLToPath(new URL('../', import.meta.url)),
  bundle: true,
  write: false,
  platform: 'node',
  format: 'esm',
  plugins: [{
    name: 'notification-receipt',
    setup(builder) {
      builder.onResolve({ filter: /^\.\/client$/ }, () => ({ path: 'client', namespace: 'fixture' }));
      builder.onLoad({ filter: /.*/, namespace: 'fixture' }, () => ({ contents: `
        export const toV2PagedResult = response => response;
        export const v2Request = async () => globalThis.notificationReceipt;
        export const v2RequestData = async () => (await v2Request()).data;
      ` }));
    }
  }]
});
const api = await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);

test('notification actions confirm the requested write', async () => {
  const read = { notification_id: 42, is_read: 1, read_at: '2026-11-20T00:00:00Z' };
  const restored = { notification_id: 42, deleted_at: null };
  const deleted = { code: 200, message: 'notification deleted', data: null, meta: null };
  const cases = [
    [() => api.v2SetNotificationReadStatus(42, { is_read: true }), { data: read },
      [{ data: { ...read, notification_id: 43 } }, { data: { ...read, is_read: 0 } }]],
    [() => api.v2SetNotificationReadStatus(42, { is_read: false }), { data: { ...read, is_read: 0, read_at: null } },
      [{ data: { ...read, is_read: 0 } }]],
    [() => api.v2RestoreNotification(42), { data: restored },
      [{ data: { notification_id: 42 } }, { data: { ...restored, notification_id: 43 } }]],
    [() => api.v2DeleteNotification(42), deleted,
      [{ ...deleted, message: 'OK' }, { ...deleted, data: {} }, { ...deleted, meta: undefined }]]
  ];
  for (const [perform, valid, invalid] of cases) {
    globalThis.notificationReceipt = valid;
    await perform();
    for (const receipt of invalid) {
      globalThis.notificationReceipt = receipt;
      await assert.rejects(perform, /Invalid notification/);
    }
  }
});
