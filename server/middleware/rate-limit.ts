import { createError, defineEventHandler, getRequestURL, setResponseHeader } from 'h3';
import type { H3Event } from 'h3';
import type Redis from 'ioredis';
import { getClientIp } from '../utils/client-ip';
import { logWarn } from '../utils/logging';

const policies = {
  auth: [10, 60], ai: [10, 60], transfer: [10, 60], write: [40, 10], read: [100, 10]
} as const;
type Tier = keyof typeof policies;

function tierFor(method: string, path: string): Tier {
  if (path.startsWith('/auth/')) {
    const session = /^\/auth\/sessions(?:\/|$)/.test(path);
    if (!(session && (method === 'GET' || method === 'DELETE')) &&
        !(method === 'DELETE' && path === '/auth/tokens/current')) return 'auth';
  }
  if ((method === 'PATCH' && path === '/users/me/email') ||
      (method === 'POST' && /^\/users\/me\/two-factor\/(setup|confirm)$/.test(path)) ||
      (method === 'DELETE' && path === '/users/me/two-factor')) return 'auth';
  if (method === 'POST' && (/^\/ai\/conversations\/[^/]+\/(generate|knowledge-generate|group-generate|moderation-generate)$/.test(path) ||
      path === '/ai/media/describe' || path === '/users/me/ai-provider/test')) return 'ai';
  if ((method === 'GET' && path === '/users/me/export') ||
      (method === 'PUT' && path === '/users/me/avatar') ||
      (method === 'POST' && (path === '/media' || path === '/media/private'))) return 'transfer';
  return method === 'GET' || method === 'HEAD' ? 'read' : 'write';
}

const fixedWindow = `
local used = redis.call('GET', KEYS[1])
if not used then
  redis.call('SET', KEYS[1], 1, 'PX', ARGV[2])
  return {1, tonumber(ARGV[1]) - 1, tonumber(ARGV[2])}
end
local ttl = redis.call('PTTL', KEYS[1])
if tonumber(used) >= tonumber(ARGV[1]) then return {0, 0, ttl} end
return {1, tonumber(ARGV[1]) - redis.call('INCR', KEYS[1]), ttl}
`;

async function admit(event: H3Event, tier: Tier, v2: boolean) {
  const { aiQuotaRedis, redis } = event.context as {aiQuotaRedis?: Redis; redis?: Redis};
  const client = aiQuotaRedis ?? redis;
  if (!client) return;
  const ip = getClientIp(event);
  const [limit, seconds] = policies[tier];
  const key = v2 ? `neko:v2:admission:1:${tier}:${ip}` : `rate_limit:window:1:${ip}`;
  let result: unknown;
  try {
    result = await client.eval(fixedWindow, 1, key, limit, seconds * 1000);
    if (!Array.isArray(result) || result.length !== 3 || !result.every(Number.isSafeInteger) ||
        ![0, 1].includes(result[0]) || result[1] < 0 || result[2] < 0) throw Error();
  } catch {
    logWarn('rate-limit', { event: 'redis:unavailable' });
    return;
  }
  const [allowed, remaining, ttl] = result as [number, number, number];
  const reset = Math.max(1, Math.ceil(ttl / 1000));
  if (v2) {
    setResponseHeader(event, 'RateLimit-Limit', limit);
    setResponseHeader(event, 'RateLimit-Remaining', remaining);
    setResponseHeader(event, 'RateLimit-Reset', reset);
  }
  if (allowed) return;
  const message = '请求过于频繁，请稍后再试';
  if (v2) setResponseHeader(event, 'Retry-After', reset);
  throw createError({
    statusCode: 429, message,
    data: v2 ? { code: 42901, message, data: null, meta: null }
      : { success: false, message, code: 429, timestamp: new Date().toISOString() }
  });
}

// Runs after CORS and before auth can update a session.
export const v2Admission = defineEventHandler(event => {
  const pathname = getRequestURL(event).pathname.replace(/\/+$/, '');
  if (event.method === 'OPTIONS' || !pathname.startsWith('/api/v2/')) return;
  const path = pathname.slice('/api/v2'.length);
  if (/^\/integrations\/sentiment-flow(?:\/|$)/.test(path)) return;
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  return admit(event, tierFor(event.method, path), true);
});

export default defineEventHandler(event => {
  const path = getRequestURL(event).pathname;
  if (path.startsWith('/api/v2/') || path === '/api/v2' || path.startsWith('/__') ||
      path.startsWith('/_nuxt') || path === '/api/health' || path === '/api/ready' ||
      /^\/metrics\/*$/.test(path) || path === '/_ws' || path.startsWith('/internal/') ||
      event.method === 'OPTIONS') return;
  return admit(event, 'read', false);
});
