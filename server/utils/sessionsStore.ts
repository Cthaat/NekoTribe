import { promises as fs } from 'fs';
import path from 'path';

/**
 * 简易文件存储的会话管理（开发/演示用）
 * - 以 userId 分桶保存各自的会话列表
 * - tokenSuffix：用来标记“当前设备”，来源于 token 后 6 位
 * - 生产环境应替换为数据库持久化
 */

const STORE_PATH = path.resolve(
  process.cwd(),
  'temp',
  'sessions.json'
);

export interface UserSession {
  id: string;
  userId: number;
  device: string;
  ip: string;
  userAgent: string;
  location?: string;
  createdAt: string;
  lastAccessedAt: string;
  tokenSuffix?: string;
}

interface StoreShape {
  [userId: string]: UserSession[];
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

function seedForUser(
  userId: number,
  tokenSuffix?: string
): UserSession[] {
  // 生成 3 条示例会话数据，便于前端展示
  const now = Date.now();
  const mk = (
    i: number,
    extra: Partial<UserSession> = {}
  ): UserSession => ({
    id: `sess_${userId}_${i}`,
    userId,
    device:
      i === 0
        ? 'This device'
        : i === 1
          ? 'Windows • Chrome'
          : 'iPhone • Safari',
    ip:
      i === 2
        ? '240e:3b1:abcd:1::123'
        : `192.168.1.${100 + i}`,
    userAgent:
      i === 0
        ? 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/127'
        : 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148',
    location: i === 2 ? 'IPv6/Unknown' : 'Local',
    createdAt: new Date(
      now - 1000 * 60 * 60 * 24 * (7 - i)
    ).toISOString(),
    lastAccessedAt: new Date(
      now - 1000 * 60 * (20 * i)
    ).toISOString(),
    ...extra
  });
  const list: UserSession[] = [mk(0), mk(1), mk(2)];
  if (tokenSuffix) list[0].tokenSuffix = tokenSuffix;
  return list;
}

export async function getSessions(options: {
  userId: number;
  tokenSuffix?: string;
}) {
  const store = await ensureStore();
  if (!store[options.userId]) {
    store[options.userId] = seedForUser(
      options.userId,
      options.tokenSuffix
    );
    await saveStore(store);
  }
  // 如果传入 tokenSuffix，但现有列表没有，则把第一条标记为当前
  if (options.tokenSuffix) {
    const has = store[options.userId].some(
      s => s.tokenSuffix === options.tokenSuffix
    );
    if (!has) {
      store[options.userId][0].tokenSuffix =
        options.tokenSuffix;
      await saveStore(store);
    }
  }
  return store[options.userId];
}

export async function revokeSession(
  userId: number,
  sessionId: string
) {
  const store = await ensureStore();
  const list = store[userId] || [];
  const idx = list.findIndex(s => s.id === sessionId);
  if (idx === -1)
    throw createError({
      statusCode: 404,
      statusMessage: 'Session not found'
    });
  list.splice(idx, 1);
  store[userId] = list;
  await saveStore(store);
}

export async function revokeAllExcept(
  userId: number,
  tokenSuffix?: string
) {
  const store = await ensureStore();
  const list = store[userId] || [];
  store[userId] = tokenSuffix
    ? list.filter(s => s.tokenSuffix === tokenSuffix)
    : [];
  await saveStore(store);
}
