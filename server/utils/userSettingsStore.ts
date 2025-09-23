import { promises as fs } from 'fs';
import path from 'path';

const STORE_PATH = path.resolve(
  process.cwd(),
  'temp',
  'user-settings.json'
);

/**
 * 用户设置文件存储（开发/演示用）
 * - 提供默认值
 * - 支持按 userId 获取/更新（合并 patch）
 */
export interface UserSettings {
  userId: number;
  twoFactorEnabled: boolean;
  loginAlerts: boolean;
  // privacy
  profile_visibility: 'public' | 'private';
  show_online_status: boolean;
  allow_dm_from_strangers: boolean;
  // notifications
  push_notification_enabled: boolean;
  email_notification_enabled: boolean;
}

interface StoreShape {
  [userId: string]: UserSettings;
}

async function ensureStore(): Promise<StoreShape> {
  try {
    const data = await fs.readFile(STORE_PATH, 'utf-8');
    return JSON.parse(data);
  } catch {
    try {
      await fs.mkdir(path.dirname(STORE_PATH), {
        recursive: true
      });
    } catch {}
    const empty: StoreShape = {};
    await fs.writeFile(
      STORE_PATH,
      JSON.stringify(empty, null, 2),
      'utf-8'
    );
    return empty;
  }
}

async function saveStore(store: StoreShape) {
  await fs.writeFile(
    STORE_PATH,
    JSON.stringify(store, null, 2),
    'utf-8'
  );
}

function defaults(userId: number): UserSettings {
  // 新用户默认配置
  return {
    userId,
    twoFactorEnabled: false,
    loginAlerts: true,
    profile_visibility: 'public',
    show_online_status: true,
    allow_dm_from_strangers: false,
    push_notification_enabled: true,
    email_notification_enabled: true
  };
}

export async function getUserSettings(
  userId: number
): Promise<UserSettings> {
  const store = await ensureStore();
  if (!store[userId]) {
    store[userId] = defaults(userId);
    await saveStore(store);
  }
  return store[userId];
}

export async function updateUserSettings(
  userId: number,
  patch: Partial<UserSettings>
): Promise<UserSettings> {
  // 合并更新：以现有配置为基，覆盖 patch 字段
  const store = await ensureStore();
  const current = store[userId] || defaults(userId);
  const merged = { ...current, ...patch, userId };
  store[userId] = merged;
  await saveStore(store);
  return merged;
}
