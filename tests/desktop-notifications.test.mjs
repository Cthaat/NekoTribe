import assert from 'node:assert/strict';
import { test } from 'node:test';
import { desktopNotificationsEnabled, desktopNotificationsSupported, setDesktopNotificationsEnabled,
  showDesktopNotification } from '../app/utils/desktop-notifications.ts';

test('only an opted-in account receives a generic desktop notification in the background', t => {
  const saved = new Map();
  const shown = [];
  class DesktopNotice {
    static permission = 'granted';
    constructor(title, options) { shown.push([title, options]); }
    close() { this.closed = true; }
  }
  const browser = { isSecureContext: true, Notification: DesktopNotice, localStorage: {
    getItem: key => saved.get(key), setItem: (key, value) => saved.set(key, value), removeItem: key => saved.delete(key),
  } };
  const page = { visibilityState: 'hidden' };
  Object.defineProperty(globalThis, 'window', { configurable: true, value: browser });
  Object.defineProperty(globalThis, 'document', { configurable: true, value: page });
  t.after(() => { delete globalThis.window; delete globalThis.document; });
  const settings = { push_notification_enabled: true, notify_like: true, notify_comment: true, notify_follow: true, notify_mention: true };
  let clicks = 0;
  const input = { userId: 49, type: 'mention', settings, title: 'New NekoTribe notification', body: 'Open your inbox to view it.', activate: () => clicks++ };

  assert.ok(desktopNotificationsSupported());
  assert.equal(showDesktopNotification(input), null);
  assert.ok(setDesktopNotificationsEnabled(input.userId, true));
  assert.equal(desktopNotificationsEnabled(50), false);
  const notice = showDesktopNotification(input);
  assert.deepEqual(shown, [[input.title, {body: input.body, tag:'nekotribe-inbox-49'}]]);
  notice.onclick();
  assert.equal(notice.closed, true);
  assert.equal(clicks, 1);
  assert.equal(showDesktopNotification({ ...input, userId: 50 }), null);
  assert.equal(showDesktopNotification({ ...input, settings: { ...settings, notify_mention: false } }), null);
  assert.equal(showDesktopNotification({ ...input, settings: { ...settings, push_notification_enabled: false } }), null);
  page.visibilityState = 'visible';
  assert.equal(showDesktopNotification(input), null);
  page.visibilityState = 'hidden';
  DesktopNotice.permission = 'denied';
  assert.equal(showDesktopNotification(input), null);
  DesktopNotice.permission = 'granted';
  assert.ok(setDesktopNotificationsEnabled(input.userId, false));
  assert.equal(showDesktopNotification(input), null);
  browser.isSecureContext = false;
  assert.equal(desktopNotificationsSupported(), false);
});
