import { promises as fs } from 'fs';
import path from 'path';

/**
 * 账户状态（通知/警告/违规）文件存储（开发/演示用）
 * - 支持按用户存储列表、分页筛选
 * - 提供更新状态与创建申诉的能力
 * - 生产环境请替换为数据库实现
 */

const STORE_PATH = path.resolve(
  process.cwd(),
  'temp',
  'statements.json'
);

type StatementType =
  | 'info'
  | 'warning'
  | 'strike'
  | 'suspension';
type StatementStatus =
  | 'unread'
  | 'read'
  | 'resolved'
  | 'dismissed'
  | 'appealed';

export interface StatementAppeal {
  id: string;
  message: string;
  createdAt: string;
  status: 'pending' | 'approved' | 'rejected';
  response?: string;
}

export interface AccountStatement {
  id: string;
  userId: number;
  type: StatementType;
  title: string;
  message: string;
  policy?: string;
  createdAt: string;
  status: StatementStatus;
  appeal?: StatementAppeal;
}

interface StoreShape {
  [userId: string]: AccountStatement[];
}

async function ensureStore(): Promise<StoreShape> {
  try {
    const data = await fs.readFile(STORE_PATH, 'utf-8');
    return JSON.parse(data);
  } catch {
    // ensure directory
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

function seedForUser(userId: number): AccountStatement[] {
  const now = new Date();
  const iso = (d: Date) => d.toISOString();
  return [
    {
      id: `st_${userId}_1`,
      userId,
      type: 'warning',
      title: 'Potential policy violation',
      message:
        'Your recent activity may violate our community guidelines. Please review and ensure compliance.',
      policy: 'CG-101',
      createdAt: iso(
        new Date(now.getTime() - 1000 * 60 * 60 * 24 * 2)
      ),
      status: 'unread'
    },
    {
      id: `st_${userId}_2`,
      userId,
      type: 'info',
      title: 'Account review completed',
      message:
        'We have completed a routine review of your account. No action is required at this time.',
      createdAt: iso(
        new Date(now.getTime() - 1000 * 60 * 60 * 24 * 7)
      ),
      status: 'read'
    },
    {
      id: `st_${userId}_3`,
      userId,
      type: 'strike',
      title: 'Content removed due to policy violation',
      message:
        'One of your posts was removed for violating the platform rules. Repeated violations may result in additional restrictions.',
      policy: 'CG-207',
      createdAt: iso(
        new Date(now.getTime() - 1000 * 60 * 60 * 5)
      ),
      status: 'unread'
    }
  ];
}

export async function getStatements(options: {
  userId: number;
  page?: number;
  pageSize?: number;
  status?: StatementStatus | 'all';
  type?: StatementType | 'all';
}) {
  // 读取与筛选
  const { userId } = options;
  const store = await ensureStore();
  if (!store[userId]) {
    store[userId] = seedForUser(userId);
    await saveStore(store);
  }
  let list = store[userId];
  if (options.status && options.status !== 'all') {
    list = list.filter(x => x.status === options.status);
  }
  if (options.type && options.type !== 'all') {
    list = list.filter(x => x.type === options.type);
  }
  // 分页
  const total = list.length;
  const page = Math.max(1, options.page || 1);
  const pageSize = Math.min(
    100,
    Math.max(1, options.pageSize || 10)
  );
  const start = (page - 1) * pageSize;
  const end = start + pageSize;
  return {
    items: list.slice(start, end),
    total,
    page,
    pageSize
  };
}

export async function updateStatement(
  userId: number,
  id: string,
  patch: Partial<AccountStatement>
) {
  // 简易更新：直接替换合并目标项
  const store = await ensureStore();
  const list = store[userId] || [];
  const idx = list.findIndex(s => s.id === id);
  if (idx === -1)
    throw createError({
      statusCode: 404,
      statusMessage: 'Statement not found'
    });
  list[idx] = { ...list[idx], ...patch };
  store[userId] = list;
  await saveStore(store);
  return list[idx];
}

export async function createAppeal(
  userId: number,
  id: string,
  message: string
) {
  // 创建申诉并将状态标记为 appealed
  const store = await ensureStore();
  const list = store[userId] || [];
  const idx = list.findIndex(s => s.id === id);
  if (idx === -1)
    throw createError({
      statusCode: 404,
      statusMessage: 'Statement not found'
    });
  const appeal: StatementAppeal = {
    id: `ap_${Date.now()}`,
    message,
    createdAt: new Date().toISOString(),
    status: 'pending'
  };
  list[idx] = { ...list[idx], status: 'appealed', appeal };
  store[userId] = list;
  await saveStore(store);
  return list[idx];
}
