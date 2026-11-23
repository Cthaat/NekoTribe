import type { UserPreference } from '@/stores/type';

type NotificationPreferences = Pick<UserPreference,
  'push_notification_enabled' | 'notify_like' | 'notify_comment' | 'notify_follow' | 'notify_mention'>;

function devicePreferenceKey(userId: number): string | null {
  return Number.isSafeInteger(userId) && userId > 0 ? `nekotribe:desktop-notifications:${userId}` : null;
}

export function desktopNotificationsSupported(): boolean {
  return typeof window !== 'undefined' && window.isSecureContext && typeof window.Notification === 'function';
}

export function desktopNotificationsEnabled(userId: number): boolean {
  const key = devicePreferenceKey(userId);
  if (!key) return false;
  try { return window.localStorage.getItem(key) === 'enabled'; } catch { return false; }
}

export function setDesktopNotificationsEnabled(userId: number, enabled: boolean): boolean {
  const key = devicePreferenceKey(userId);
  if (!key) return false;
  try {
    if (enabled) window.localStorage.setItem(key, 'enabled');
    else window.localStorage.removeItem(key);
    return true;
  } catch { return false; }
}

function permitsNotification(type: string, settings: NotificationPreferences): boolean {
  if (!settings.push_notification_enabled) return false;
  switch (type) {
    case 'like': return settings.notify_like;
    case 'comment':
    case 'comment_created':
    case 'comment_reply':
    case 'group_comment': return settings.notify_comment;
    case 'follow': return settings.notify_follow;
    case 'mention': return settings.notify_mention;
    default: return true;
  }
}

export function showDesktopNotification({ userId, type, settings, title, body, activate }: {
  userId: number;
  type: string;
  settings: NotificationPreferences;
  title: string;
  body: string;
  activate: () => void;
}): Notification | null {
  if (!permitsNotification(type, settings) || !desktopNotificationsSupported() ||
      window.Notification.permission !== 'granted' || document.visibilityState !== 'hidden' ||
      !desktopNotificationsEnabled(userId)) return null;

  try {
    const notification = new window.Notification(title, { body, tag: `nekotribe-inbox-${userId}` });
    notification.onclick = () => { notification.close(); activate(); };
    return notification;
  } catch { return null; }
}
