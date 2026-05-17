import { createHash } from 'node:crypto';
import type Redis from 'ioredis';
import type { H3Event } from 'h3';
import { getRequestURL } from 'h3';
import {
  getRequestLogContext,
  logInfo,
  logWarn,
  serializeLogError
} from './logging';

const CACHE_SCHEMA_VERSION = '1';
const CACHE_KEY_PREFIX = 'nt:api-cache';
const HIT_KEY_PREFIX = 'nt:api-cache-hits';
const TAG_VERSION_KEY_PREFIX = 'nt:api-cache-tag';
const TAG_VERSION_TTL_SECONDS = 7 * 24 * 60 * 60;

interface CacheAuthPayload {
  userId?: number;
  sessionId?: string;
  jti?: string;
}

interface CacheEventContext {
  redis?: Redis;
  auth?: CacheAuthPayload;
}

interface ApiCacheTtlPolicy {
  ttlSeconds: number;
  maxTtlSeconds: number;
}

export interface ApiResponseCacheContext {
  namespace: string;
  method: string;
  path: string;
  key: string;
  hitKey: string;
  cacheId: string;
  tags: string[];
  ttlSeconds: number;
  maxTtlSeconds: number;
}

export type ApiResponseCacheLookup<T> =
  | {
      status: 'bypass';
      reason: string;
    }
  | {
      status: 'hit';
      context: ApiResponseCacheContext;
      value: T;
    }
  | {
      status: 'miss';
      context: ApiResponseCacheContext;
    };

interface StoredCacheEntry<T> {
  schema_version: string;
  cache_id: string;
  created_at: string;
  ttl_seconds: number;
  tags: string[];
  payload: T;
}

function methodOf(event: H3Event): string {
  return (event.node.req.method || 'GET').toUpperCase();
}

function redisOf(event: H3Event): Redis | null {
  const context = event.context as CacheEventContext;
  return context.redis ?? null;
}

function authOf(event: H3Event): CacheAuthPayload | null {
  const context = event.context as CacheEventContext;
  return context.auth ?? null;
}

function hash(input: string): string {
  return createHash('sha256').update(input).digest('hex');
}

function normalizeKeyPart(input: string): string {
  const normalized = input
    .toLowerCase()
    .replace(/[^a-z0-9:_-]+/g, ':')
    .replace(/:{2,}/g, ':')
    .replace(/^:+|:+$/g, '');
  return normalized || 'root';
}

function safeDecode(value: string): string {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

function pathSegments(pathname: string): string[] {
  return pathname
    .replace(/^\/api\/v2\/?/, '')
    .split('/')
    .filter(Boolean)
    .map(segment => safeDecode(segment));
}

function isNumericSegment(value: string | undefined): boolean {
  return typeof value === 'string' && /^[1-9]\d*$/.test(value);
}

function addTag(tags: Set<string>, value: string): void {
  const tag = normalizeKeyPart(value);
  if (tag) tags.add(tag);
}

function addEntityTag(
  tags: Set<string>,
  type: string,
  value: string | undefined
): void {
  if (!value) return;
  addTag(tags, `${type}:${value}`);
}

function addAuthenticatedViewerTag(
  tags: Set<string>,
  auth: CacheAuthPayload | null
): void {
  if (auth?.userId) {
    addTag(tags, `viewer:${auth.userId}`);
  } else {
    addTag(tags, 'viewer:anonymous');
  }
}

function addCommonPostTags(tags: Set<string>): void {
  addTag(tags, 'posts');
  addTag(tags, 'users');
  addTag(tags, 'tags');
}

function addCommonGroupTags(tags: Set<string>): void {
  addTag(tags, 'groups');
  addTag(tags, 'users');
}

function tagsForPath(
  pathname: string,
  auth: CacheAuthPayload | null
): string[] {
  const segments = pathSegments(pathname);
  const [root, second, third, fourth] = segments;
  const tags = new Set<string>();

  addAuthenticatedViewerTag(tags, auth);

  switch (root) {
    case 'posts':
      addCommonPostTags(tags);
      if (isNumericSegment(second)) {
        addEntityTag(tags, 'post', second);
        if (third) addEntityTag(tags, `post:${second}`, third);
      }
      if (second === 'trending') addTag(tags, 'trending');
      break;
    case 'comments':
      addCommonPostTags(tags);
      addTag(tags, 'comments');
      if (isNumericSegment(second)) {
        addEntityTag(tags, 'comment', second);
      }
      break;
    case 'users':
      addTag(tags, 'users');
      if (second === 'me') {
        addTag(tags, 'account');
        if (auth?.userId) addEntityTag(tags, 'user', String(auth.userId));
        if (third === 'posts' || third === 'bookmarks') {
          addTag(tags, 'posts');
        }
        if (third === 'groups') addTag(tags, 'groups');
        if (
          [
            'blocks',
            'mutes',
            'followers',
            'following'
          ].includes(third ?? '')
        ) {
          addTag(tags, 'relationships');
        }
      } else if (isNumericSegment(second)) {
        addEntityTag(tags, 'user', second);
        if (['posts', 'analytics'].includes(third ?? '')) {
          addTag(tags, 'posts');
        }
        if (
          [
            'followers',
            'following',
            'mutual-following'
          ].includes(third ?? '')
        ) {
          addTag(tags, 'relationships');
        }
      }
      break;
    case 'groups':
      addCommonGroupTags(tags);
      if (isNumericSegment(second)) {
        addEntityTag(tags, 'group', second);
      }
      if (second === 'by-slug') {
        addEntityTag(tags, 'group-slug', third);
      }
      if (second === 'popular') addTag(tags, 'trending');
      if (segments.includes('posts')) addTag(tags, 'posts');
      if (segments.includes('members')) addTag(tags, 'relationships');
      if (segments.includes('invites')) addTag(tags, 'account');
      if (isNumericSegment(fourth)) addEntityTag(tags, 'group-post', fourth);
      break;
    case 'chat':
      addTag(tags, 'chat');
      addCommonGroupTags(tags);
      if (isNumericSegment(third)) {
        addEntityTag(
          tags,
          second === 'groups' ? 'group' : second ?? 'chat-resource',
          third
        );
      }
      if (isNumericSegment(fourth)) {
        addEntityTag(tags, third ?? 'chat-resource', fourth);
      }
      break;
    case 'notifications':
      addTag(tags, 'notifications');
      addTag(tags, 'users');
      if (auth?.userId) addEntityTag(tags, 'user', String(auth.userId));
      if (isNumericSegment(second)) {
        addEntityTag(tags, 'notification', second);
      }
      break;
    case 'moderation':
      addTag(tags, 'moderation');
      addTag(tags, 'posts');
      addTag(tags, 'users');
      addTag(tags, 'groups');
      break;
    case 'tags':
      addTag(tags, 'tags');
      addTag(tags, 'posts');
      if (second === 'trending') addTag(tags, 'trending');
      if (second && second !== 'trending') addEntityTag(tags, 'tag', second);
      break;
    case 'auth':
      addTag(tags, 'auth');
      if (second === 'sessions') {
        addTag(tags, 'account');
        if (auth?.userId) addEntityTag(tags, 'user', String(auth.userId));
      }
      if (second === 'registration') addTag(tags, 'users');
      break;
    case 'media':
      addTag(tags, 'media');
      addTag(tags, 'posts');
      addTag(tags, 'users');
      break;
    case 'reports':
      addTag(tags, 'moderation');
      addTag(tags, 'posts');
      addTag(tags, 'users');
      break;
    default:
      addTag(tags, root || 'v2');
      break;
  }

  return [...tags].sort();
}

function ttlPolicyForPath(pathname: string): ApiCacheTtlPolicy {
  const segments = pathSegments(pathname);
  const [root, second, third] = segments;

  if (
    root === 'chat' ||
    root === 'notifications' ||
    (root === 'auth' && second === 'sessions')
  ) {
    return { ttlSeconds: 20, maxTtlSeconds: 120 };
  }

  if (root === 'moderation') {
    return { ttlSeconds: 45, maxTtlSeconds: 240 };
  }

  if (
    (root === 'posts' && second === 'trending') ||
    (root === 'groups' && second === 'popular') ||
    (root === 'tags' && second === 'trending')
  ) {
    return { ttlSeconds: 300, maxTtlSeconds: 900 };
  }

  if (
    (root === 'posts' && isNumericSegment(second) && !third) ||
    (root === 'groups' && isNumericSegment(second) && !third) ||
    (root === 'users' && isNumericSegment(second) && !third)
  ) {
    return { ttlSeconds: 120, maxTtlSeconds: 600 };
  }

  if (
    root === 'posts' ||
    root === 'groups' ||
    root === 'users' ||
    root === 'tags'
  ) {
    return { ttlSeconds: 90, maxTtlSeconds: 480 };
  }

  return { ttlSeconds: 60, maxTtlSeconds: 300 };
}

function canonicalQuery(url: URL): string {
  const entries = [...url.searchParams.entries()].sort(
    (left, right) => {
      const keyCompare = left[0].localeCompare(right[0]);
      return keyCompare === 0
        ? left[1].localeCompare(right[1])
        : keyCompare;
    }
  );
  return new URLSearchParams(entries).toString();
}

function sessionScoped(pathname: string): boolean {
  return pathname.startsWith('/api/v2/auth/sessions');
}

function scopeForRequest(
  pathname: string,
  auth: CacheAuthPayload | null
): string {
  if (!auth?.userId) return 'anonymous';
  if (!sessionScoped(pathname)) return `user:${auth.userId}`;

  const sessionToken =
    auth.sessionId || auth.jti || `user:${auth.userId}`;
  return `user:${auth.userId}:session:${hash(sessionToken).slice(0, 16)}`;
}

async function tagVersions(
  redis: Redis,
  namespace: string,
  tags: string[]
): Promise<Array<[string, string]>> {
  const keys = tags.map(
    tag => `${TAG_VERSION_KEY_PREFIX}:${namespace}:${tag}`
  );
  const values = keys.length > 0 ? await redis.mget(...keys) : [];
  return tags.map((tag, index) => [tag, values[index] ?? '0']);
}

function cacheLabel(pathname: string): string {
  return normalizeKeyPart(
    pathname.replace(/^\/api\/v2\/?/, '')
  ).slice(0, 80);
}

function isStoredCacheEntry<T>(
  value: unknown
): value is StoredCacheEntry<T> {
  return (
    !!value &&
    typeof value === 'object' &&
    'schema_version' in value &&
    'cache_id' in value &&
    'payload' in value
  );
}

async function buildCacheContext(
  event: H3Event,
  namespace: string,
  redis: Redis
): Promise<ApiResponseCacheContext | null> {
  const method = methodOf(event);
  if (method !== 'GET') return null;

  const url = getRequestURL(event);
  if (!url.pathname.startsWith('/api/v2/')) return null;

  const auth = authOf(event);
  const tags = tagsForPath(url.pathname, auth);
  const versions = await tagVersions(redis, namespace, tags);
  const scope = scopeForRequest(url.pathname, auth);
  const identity = JSON.stringify({
    schema: CACHE_SCHEMA_VERSION,
    namespace,
    method,
    path: url.pathname,
    query: canonicalQuery(url),
    scope,
    tag_versions: versions
  });
  const cacheId = hash(identity);
  const policy = ttlPolicyForPath(url.pathname);
  const label = cacheLabel(url.pathname);

  return {
    namespace,
    method,
    path: url.pathname,
    key: `${CACHE_KEY_PREFIX}:${namespace}:${label}:${cacheId}`,
    hitKey: `${HIT_KEY_PREFIX}:${namespace}:${cacheId}`,
    cacheId,
    tags,
    ttlSeconds: policy.ttlSeconds,
    maxTtlSeconds: policy.maxTtlSeconds
  };
}

function ttlWithJitter(context: ApiResponseCacheContext): number {
  const jitterRange = Math.max(
    1,
    Math.min(30, Math.floor(context.ttlSeconds * 0.1))
  );
  const jitter =
    Number.parseInt(context.cacheId.slice(0, 2), 16) %
    jitterRange;
  return Math.min(context.maxTtlSeconds, context.ttlSeconds + jitter);
}

async function extendHotCacheTtl(
  redis: Redis,
  context: ApiResponseCacheContext
): Promise<number> {
  const hits = await redis.incr(context.hitKey);
  const boostSteps = Math.min(
    5,
    Math.floor(Math.log2(Math.max(hits, 1)))
  );
  const nextTtl = Math.min(
    context.maxTtlSeconds,
    context.ttlSeconds * (1 + boostSteps)
  );

  const pipeline = redis.pipeline();
  pipeline.expire(context.key, nextTtl);
  pipeline.expire(context.hitKey, context.maxTtlSeconds);
  await pipeline.exec();
  return nextTtl;
}

function cacheLogPayload(
  event: H3Event,
  context?: ApiResponseCacheContext
): Record<string, unknown> {
  const logContext = getRequestLogContext(event);
  return {
    requestId: logContext?.requestId ?? 'unknown',
    method: methodOf(event),
    path: context?.path ?? getRequestURL(event).pathname,
    cacheId: context?.cacheId,
    tags: context?.tags
  };
}

export async function readApiResponseCache<T>(
  event: H3Event,
  namespace: string
): Promise<ApiResponseCacheLookup<T>> {
  const redis = redisOf(event);
  if (!redis) {
    return { status: 'bypass', reason: 'redis_missing' };
  }

  let context: ApiResponseCacheContext | null = null;
  try {
    context = await buildCacheContext(event, namespace, redis);
    if (!context) {
      return { status: 'bypass', reason: 'not_cacheable' };
    }

    const raw = await redis.get(context.key);
    if (!raw) {
      return { status: 'miss', context };
    }

    const parsed = JSON.parse(raw) as unknown;
    if (!isStoredCacheEntry<T>(parsed)) {
      await redis.del(context.key);
      return { status: 'miss', context };
    }

    const nextTtl = await extendHotCacheTtl(redis, context);
    logInfo('api-cache', {
      event: 'hit',
      ...cacheLogPayload(event, context),
      ttlSeconds: nextTtl
    });

    return {
      status: 'hit',
      context,
      value: parsed.payload
    };
  } catch (error) {
    logWarn('api-cache', {
      event: 'read:error',
      ...cacheLogPayload(event, context ?? undefined),
      error: serializeLogError(error)
    });
    return { status: 'bypass', reason: 'redis_error' };
  }
}

export async function writeApiResponseCache<T>(
  event: H3Event,
  context: ApiResponseCacheContext,
  payload: T
): Promise<void> {
  const redis = redisOf(event);
  if (!redis) return;

  const ttlSeconds = ttlWithJitter(context);
  const entry: StoredCacheEntry<T> = {
    schema_version: CACHE_SCHEMA_VERSION,
    cache_id: context.cacheId,
    created_at: new Date().toISOString(),
    ttl_seconds: ttlSeconds,
    tags: context.tags,
    payload
  };

  try {
    const pipeline = redis.pipeline();
    pipeline.set(context.key, JSON.stringify(entry), 'EX', ttlSeconds);
    pipeline.set(context.hitKey, '0', 'EX', context.maxTtlSeconds);
    await pipeline.exec();
    logInfo('api-cache', {
      event: 'write',
      ...cacheLogPayload(event, context),
      ttlSeconds
    });
  } catch (error) {
    logWarn('api-cache', {
      event: 'write:error',
      ...cacheLogPayload(event, context),
      error: serializeLogError(error)
    });
  }
}

function isCacheNeutralMutation(pathname: string, method: string): boolean {
  if (pathname === '/api/v2/auth/otp') return true;
  if (pathname === '/api/v2/auth/otp/verification') return true;
  return method === 'PATCH' && pathname === '/api/v2/auth/tokens/current';
}

export function shouldInvalidateApiResponseCache(event: H3Event): boolean {
  const method = methodOf(event);
  if (['GET', 'HEAD', 'OPTIONS'].includes(method)) return false;

  const pathname = getRequestURL(event).pathname;
  return (
    pathname.startsWith('/api/v2/') &&
    !isCacheNeutralMutation(pathname, method)
  );
}

export async function invalidateApiResponseCache(
  event: H3Event,
  namespace: string
): Promise<void> {
  const method = methodOf(event);
  const pathname = getRequestURL(event).pathname;
  if (isCacheNeutralMutation(pathname, method)) return;

  const tags = tagsForPath(pathname, authOf(event));
  await invalidateApiResponseCacheTags(event, namespace, tags);
}

export async function invalidateApiResponseCacheTags(
  event: H3Event,
  namespace: string,
  tags: string[]
): Promise<void> {
  const redis = redisOf(event);
  if (!redis || tags.length === 0) return;

  try {
    const pipeline = redis.pipeline();
    for (const tag of tags) {
      const key = `${TAG_VERSION_KEY_PREFIX}:${namespace}:${tag}`;
      pipeline.incr(key);
      pipeline.expire(key, TAG_VERSION_TTL_SECONDS);
    }
    await pipeline.exec();
    logInfo('api-cache', {
      event: 'invalidate',
      ...cacheLogPayload(event),
      tags
    });
  } catch (error) {
    logWarn('api-cache', {
      event: 'invalidate:error',
      ...cacheLogPayload(event),
      tags,
      error: serializeLogError(error)
    });
  }
}
