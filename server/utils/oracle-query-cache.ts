import { createHash } from 'node:crypto';
import type Redis from 'ioredis';
import type { H3Event } from 'h3';
import type oracledb from 'oracledb';
import { getRequestURL } from 'h3';
import { invalidateApiResponseCacheTags } from './api-cache';
import { cacheProcessEpoch, singleBackendCacheEnabled } from './cache-mode';
import { readCacheTagVersions, rotateCacheTags } from './cache-tags';
import { observeCacheRead } from './observability';
import {
  getRequestLogContext,
  logInfo,
  logWarn,
  serializeLogError
} from './logging';

const ORACLE_QUERY_CACHE_ATTACHED: unique symbol = Symbol(
  'nekotribe.oracleQueryCacheAttached'
);
const ORACLE_QUERY_CACHE_ORIGINAL_EXECUTE: unique symbol = Symbol(
  'nekotribe.oracleQueryCacheOriginalExecute'
);
const ORACLE_QUERY_CACHE_SOURCE: unique symbol = Symbol(
  'nekotribe.oracleQueryCacheSource'
);

const QUERY_CACHE_SCHEMA_VERSION = '2';
const QUERY_CACHE_KEY_PREFIX = 'nt:oracle-query-cache';
const QUERY_HIT_KEY_PREFIX = 'nt:oracle-query-cache-hits';
const QUERY_TAG_VERSION_KEY_PREFIX = 'nt:oracle-query-cache-tag:v2';

interface OracleQueryCacheAuth {
  userId?: number;
}

interface OracleQueryCacheEventContext {
  redis?: Redis;
  auth?: OracleQueryCacheAuth;
}

interface CachedOracleConnection extends oracledb.Connection {
  [ORACLE_QUERY_CACHE_ATTACHED]?: boolean;
  [ORACLE_QUERY_CACHE_ORIGINAL_EXECUTE]?: RawOracleExecute;
  [ORACLE_QUERY_CACHE_SOURCE]?: OracleQueryCacheSource;
}

interface OracleQueryCacheContext {
  key: string;
  hitKey: string;
  cacheId: string;
  tags: string[];
  ttlSeconds: number;
  maxTtlSeconds: number;
}

interface StoredOracleQueryResult {
  schema_version: string;
  cache_id: string;
  created_at: string;
  ttl_seconds: number;
  tags: string[];
  result: unknown;
}

type RawOracleExecute = (
  ...args: unknown[]
) => Promise<oracledb.Result<unknown>>;

export interface OracleQueryCacheSource {
  event?: H3Event;
  redis?: Redis | null;
  authUserId?: number | null;
  requestId?: string;
  path?: string;
}

function cacheSourceFromEvent(
  event: H3Event
): OracleQueryCacheSource {
  const context =
    event.context as OracleQueryCacheEventContext;
  const logContext = getRequestLogContext(event);
  return {
    event,
    redis: context.redis ?? null,
    authUserId: context.auth?.userId ?? null,
    requestId: logContext?.requestId ?? 'unknown',
    path: logContext?.path ?? getRequestURL(event).pathname
  };
}

function redisOf(source: OracleQueryCacheSource): Redis | null {
  return source.redis ?? null;
}

function authUserId(source: OracleQueryCacheSource): number | null {
  return source.authUserId ?? null;
}

function hash(input: string): string {
  return createHash('sha256').update(input).digest('hex');
}

function normalizeSql(sql: string): string {
  return sql.replace(/\s+/g, ' ').trim();
}

function stripLeadingSqlComments(sql: string): string {
  let current = sql.trim();
  let previous = '';

  while (current !== previous) {
    previous = current;
    current = current
      .replace(/^--[^\n\r]*(?:\r?\n|$)/, '')
      .replace(/^\/\*[\s\S]*?\*\//, '')
      .trim();
  }

  return current;
}

function normalizedSqlForMatch(sql: string): string {
  return stripLeadingSqlComments(sql).toLowerCase();
}

function isCacheableSelectSql(sql: string): boolean {
  const normalized = normalizedSqlForMatch(sql);
  if (
    !(
      normalized.startsWith('select ') ||
      normalized.startsWith('with ')
    )
  ) {
    return false;
  }

  if (/\bnextval\b/i.test(normalized)) return false;
  if (/\bfor\s+update\b/i.test(normalized)) return false;
  // Visibility can change independently of the rows directly referenced here.
  if (/\bfn_can_view_post\s*\(/i.test(normalized)) return false;
  if (isSensitiveSql(normalized)) return false;

  return true;
}

function isSensitiveSql(normalizedSql: string): boolean {
  return [
    'password_hash',
    'access_token',
    'refresh_token',
    'access_jti',
    'refresh_jti',
    'verification_code',
    'n_auth_sessions',
    'n_user_sessions',
    'n_user_settings',
    'n_user_blocks',
    'n_user_mutes',
    'n_post_poll',
    'n_post_drafts',
    'n_user_pinned_posts',
    'n_post_markdown',
    'n_moderation_user_restrictions',
    'n_user_follows',
    'fn_get_user_relationship',
    'n_ai_conversations',
    'n_ai_messages',
    'fn_has_group_permission'
  ].some(token => normalizedSql.includes(token));
}

function isCacheNeutralMutationSql(sql: string): boolean {
  const normalized = normalizedSqlForMatch(sql);
  return (
    normalized.includes('update n_auth_sessions') &&
    normalized.includes('last_accessed_at') &&
    !normalized.includes('revoked_at')
  ) || (
    normalized.includes('update n_user_sessions') &&
    normalized.includes('last_accessed_at')
  );
}

function isMutatingSql(sql: string): boolean {
  const normalized = normalizedSqlForMatch(sql);
  return /^(insert|update|delete|merge|begin|declare)\b/.test(normalized);
}

function normalizeKeyPart(input: string): string {
  return input
    .toLowerCase()
    .replace(/[^a-z0-9:_-]+/g, ':')
    .replace(/:{2,}/g, ':')
    .replace(/^:+|:+$/g, '') || 'generic';
}

function normalizeTableName(input: string): string {
  return input
    .replace(/^"+|"+$/g, '')
    .replace(/^[\w$#]+\./, '')
    .toLowerCase();
}

function tableRefs(sql: string): string[] {
  const refs = new Set<string>();
  const normalized = normalizedSqlForMatch(sql);
  const patterns = [
    /\bfrom\s+([a-z0-9_$#."]+)/gi,
    /\bjoin\s+([a-z0-9_$#."]+)/gi,
    /\bupdate\s+([a-z0-9_$#."]+)/gi,
    /\binsert\s+into\s+([a-z0-9_$#."]+)/gi,
    /\bdelete\s+from\s+([a-z0-9_$#."]+)/gi,
    /\bmerge\s+into\s+([a-z0-9_$#."]+)/gi
  ];

  for (const pattern of patterns) {
    for (const match of normalized.matchAll(pattern)) {
      if (match[1]) refs.add(normalizeTableName(match[1]));
    }
  }

  return [...refs].sort();
}

function addTag(tags: Set<string>, value: string): void {
  tags.add(normalizeKeyPart(value));
}

function addDomainTags(
  tags: Set<string>,
  normalizedSql: string,
  tables: string[]
): void {
  const joined = `${normalizedSql} ${tables.join(' ')}`;

  if (/tweet|post|timeline|bookmark|like|reply|retweet/.test(joined)) {
    addTag(tags, 'posts');
    addTag(tags, 'tweets');
    addTag(tags, 'users');
    addTag(tags, 'tags');
    addTag(tags, 'media');
  }

  if (/comment/.test(joined)) {
    addTag(tags, 'comments');
    addTag(tags, 'posts');
    addTag(tags, 'users');
  }

  if (/user|follow|block|mute/.test(joined)) {
    addTag(tags, 'users');
  }

  if (/group|member|invite|audit/.test(joined)) {
    addTag(tags, 'groups');
  }

  if (/notification/.test(joined)) {
    addTag(tags, 'notifications');
  }

  if (/chat|channel|message|conversation|reaction/.test(joined)) {
    addTag(tags, 'chat');
    addTag(tags, 'groups');
  }

  if (/tag|hashtag/.test(joined)) {
    addTag(tags, 'tags');
    addTag(tags, 'posts');
  }

  if (/media|upload|avatar/.test(joined)) {
    addTag(tags, 'media');
    addTag(tags, 'posts');
    addTag(tags, 'users');
  }

  if (/moderation|report|appeal|statement|policy/.test(joined)) {
    addTag(tags, 'moderation');
    addTag(tags, 'posts');
    addTag(tags, 'users');
  }

  if (/session|auth|account/.test(joined)) {
    addTag(tags, 'auth');
    addTag(tags, 'account');
  }
}

function tagsForSql(
  sql: string,
  source: OracleQueryCacheSource
): string[] {
  const tags = new Set<string>(['oracle']);
  const normalized = normalizedSqlForMatch(sql);
  const tables = tableRefs(sql);

  for (const table of tables) {
    addTag(tags, `table:${table}`);
  }

  addDomainTags(tags, normalized, tables);

  const userId = authUserId(source);
  if (userId) {
    addTag(tags, `viewer:${userId}`);
  } else {
    addTag(tags, 'viewer:anonymous');
  }

  return [...tags].sort();
}

function ttlPolicyForTags(tags: string[]): {
  ttlSeconds: number;
  maxTtlSeconds: number;
} {
  const tagSet = new Set(tags);

  if (
    tagSet.has('chat') ||
    tagSet.has('notifications') ||
    tagSet.has('auth') ||
    tagSet.has('account')
  ) {
    return { ttlSeconds: 20, maxTtlSeconds: 120 };
  }

  if (tagSet.has('moderation')) {
    return { ttlSeconds: 45, maxTtlSeconds: 240 };
  }

  if (
    tagSet.has('posts') ||
    tagSet.has('tweets') ||
    tagSet.has('groups') ||
    tagSet.has('users') ||
    tagSet.has('tags')
  ) {
    return { ttlSeconds: 90, maxTtlSeconds: 480 };
  }

  return { ttlSeconds: 60, maxTtlSeconds: 300 };
}

function normalizeForCache(value: unknown): unknown {
  if (value instanceof Date) return value.toISOString();
  if (typeof value === 'bigint') return value.toString();
  if (Buffer.isBuffer(value)) {
    return {
      type: 'buffer',
      sha256: hash(value.toString('base64'))
    };
  }
  if (Array.isArray(value)) {
    return value.map(item => normalizeForCache(item));
  }
  if (value && typeof value === 'object') {
    const entries = Object.entries(
      value as Record<string, unknown>
    ).sort(([left], [right]) => left.localeCompare(right));
    return Object.fromEntries(
      entries.map(([key, item]) => [
        key,
        normalizeForCache(item)
      ])
    );
  }
  if (typeof value === 'function') return '[function]';
  if (typeof value === 'symbol') return value.toString();
  return value;
}

function executeOptionsFromArgs(args: unknown[]): unknown {
  return args.length >= 3 ? args[2] : undefined;
}

function hasUnsupportedResultValue(value: unknown): boolean {
  if (value === null || value === undefined) return false;
  if (
    typeof value === 'string' ||
    typeof value === 'number' ||
    typeof value === 'boolean'
  ) {
    return false;
  }
  if (typeof value === 'bigint') return false;
  if (value instanceof Date) return false;
  if (Buffer.isBuffer(value)) return true;
  if (Array.isArray(value)) {
    return value.some(item => hasUnsupportedResultValue(item));
  }
  if (typeof value === 'object') {
    if (Object.getPrototypeOf(value) !== Object.prototype) {
      return true;
    }
    return Object.values(value).some(item =>
      hasUnsupportedResultValue(item)
    );
  }
  return true;
}

function isCacheableResult(
  result: oracledb.Result<unknown>
): boolean {
  const candidate = result as {
    resultSet?: unknown;
    rows?: unknown;
  };
  if (candidate.resultSet) return false;
  if (candidate.rows === undefined) return false;
  return !hasUnsupportedResultValue(candidate.rows);
}

function jsonStringifyCache(value: unknown): string {
  return JSON.stringify(value, (_key, item) =>
    typeof item === 'bigint' ? item.toString() : item
  );
}

async function queryTagVersions(
  redis: Redis,
  tags: string[]
): Promise<Array<[string, string]>> {
  const keys = tags.map(
    tag => `${QUERY_TAG_VERSION_KEY_PREFIX}:oracle:${tag}`
  );
  const values = await readCacheTagVersions(redis, keys);
  return tags.map((tag, index) => [tag, values[index]!]);
}

async function buildQueryCacheContext(
  source: OracleQueryCacheSource,
  sql: string,
  binds: unknown,
  options: unknown,
  redis: Redis
): Promise<OracleQueryCacheContext> {
  const tags = tagsForSql(sql, source);
  const tagVersions = await queryTagVersions(redis, tags);
  const policy = ttlPolicyForTags(tags);
  const identity = JSON.stringify({
    schema: QUERY_CACHE_SCHEMA_VERSION,
    process_epoch: cacheProcessEpoch,
    sql: normalizeSql(sql),
    binds: normalizeForCache(binds),
    options: normalizeForCache(options),
    auth_user_id: authUserId(source),
    tag_versions: tagVersions
  });
  const cacheId = hash(identity);
  const label = normalizeKeyPart(
    tableRefs(sql)[0] ?? source.path ?? 'oracle'
  );

  return {
    key: `${QUERY_CACHE_KEY_PREFIX}:oracle:${label}:${cacheId}`,
    hitKey: `${QUERY_HIT_KEY_PREFIX}:oracle:${cacheId}`,
    cacheId,
    tags,
    ttlSeconds: policy.ttlSeconds,
    maxTtlSeconds: policy.maxTtlSeconds
  };
}

function ttlWithJitter(context: OracleQueryCacheContext): number {
  const jitterRange = Math.max(
    1,
    Math.min(30, Math.floor(context.ttlSeconds * 0.1))
  );
  const jitter =
    Number.parseInt(context.cacheId.slice(0, 2), 16) %
    jitterRange;
  return Math.min(context.maxTtlSeconds, context.ttlSeconds + jitter);
}

async function extendHotQueryTtl(
  redis: Redis,
  context: OracleQueryCacheContext
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

function queryLogPayload(
  source: OracleQueryCacheSource,
  context: OracleQueryCacheContext,
  sql: string
): Record<string, unknown> {
  return {
    requestId: source.requestId ?? 'unknown',
    path: source.path ?? 'oracle',
    cacheId: context.cacheId,
    tags: context.tags,
    sqlHash: hash(normalizeSql(sql))
  };
}

async function readOracleQueryCache(
  source: OracleQueryCacheSource,
  redis: Redis,
  context: OracleQueryCacheContext,
  sql: string
): Promise<oracledb.Result<unknown> | null> {
  try {
    const raw = await redis.get(context.key);
    if (!raw) {
      observeCacheRead('miss');
      return null;
    }

    const parsed = JSON.parse(raw) as StoredOracleQueryResult;
    if (
      parsed.schema_version !== QUERY_CACHE_SCHEMA_VERSION ||
      parsed.cache_id !== context.cacheId
    ) {
      await redis.del(context.key);
      observeCacheRead('miss');
      return null;
    }

    const ttlSeconds = await extendHotQueryTtl(redis, context);
    logInfo('oracle-query-cache', {
      event: 'hit',
      ...queryLogPayload(source, context, sql),
      ttlSeconds
    });
    observeCacheRead('hit');
    return parsed.result as oracledb.Result<unknown>;
  } catch (error) {
    observeCacheRead('degraded');
    logWarn('oracle-query-cache', {
      event: 'read:error',
      ...queryLogPayload(source, context, sql),
      error: serializeLogError(error)
    });
    return null;
  }
}

async function writeOracleQueryCache(
  source: OracleQueryCacheSource,
  redis: Redis,
  context: OracleQueryCacheContext,
  sql: string,
  result: oracledb.Result<unknown>
): Promise<void> {
  if (!isCacheableResult(result)) return;

  const ttlSeconds = ttlWithJitter(context);
  const entry: StoredOracleQueryResult = {
    schema_version: QUERY_CACHE_SCHEMA_VERSION,
    cache_id: context.cacheId,
    created_at: new Date().toISOString(),
    ttl_seconds: ttlSeconds,
    tags: context.tags,
    result
  };

  try {
    const pipeline = redis.pipeline();
    pipeline.set(
      context.key,
      jsonStringifyCache(entry),
      'EX',
      ttlSeconds
    );
    pipeline.set(context.hitKey, '0', 'EX', context.maxTtlSeconds);
    await pipeline.exec();
    logInfo('oracle-query-cache', {
      event: 'write',
      ...queryLogPayload(source, context, sql),
      ttlSeconds
    });
  } catch (error) {
    logWarn('oracle-query-cache', {
      event: 'write:error',
      ...queryLogPayload(source, context, sql),
      error: serializeLogError(error)
    });
  }
}

async function invalidateOracleQueryCacheTags(
  source: OracleQueryCacheSource,
  redis: Redis,
  tags: string[],
  sql: string
): Promise<void> {
  if (tags.length === 0) return;

  try {
    await rotateCacheTags(redis, tags.map(tag => `${QUERY_TAG_VERSION_KEY_PREFIX}:oracle:${tag}`));
    if (source.event) {
      await invalidateApiResponseCacheTags(source.event, 'v2', tags);
    }
    logInfo('oracle-query-cache', {
      event: 'invalidate',
      requestId: source.requestId ?? 'unknown',
      path: source.path ?? 'oracle',
      tags,
      sqlHash: hash(normalizeSql(sql))
    });
  } catch (error) {
    logWarn('oracle-query-cache', {
      event: 'invalidate:error',
      requestId: source.requestId ?? 'unknown',
      path: source.path ?? 'oracle',
      tags,
      sqlHash: hash(normalizeSql(sql)),
      error: serializeLogError(error)
    });
  }
}

export function attachOracleQueryCacheWithSource(
  source: OracleQueryCacheSource,
  connection: oracledb.Connection
): oracledb.Connection {
  if (!singleBackendCacheEnabled) return connection;
  const cachedConnection = connection as CachedOracleConnection;
  cachedConnection[ORACLE_QUERY_CACHE_SOURCE] = source;

  if (cachedConnection[ORACLE_QUERY_CACHE_ATTACHED]) {
    return connection;
  }

  cachedConnection[ORACLE_QUERY_CACHE_ORIGINAL_EXECUTE] =
    connection.execute.bind(connection) as RawOracleExecute;

  const pendingTags = new Set<string>();
  let operations = Promise.resolve();
  function inConnectionOrder<T>(action: () => Promise<T>): Promise<T> {
    const result = operations.then(action);
    operations = result.then(() => undefined, () => undefined);
    return result;
  }
  const currentSource = () => cachedConnection[ORACLE_QUERY_CACHE_SOURCE] ?? source;
  async function invalidatePending(current: OracleQueryCacheSource, sql: string) {
    const redis = redisOf(current);
    if (redis && pendingTags.size) {
      await invalidateOracleQueryCacheTags(current, redis, [...pendingTags], sql);
    }
  }
  if (typeof connection.commit === 'function') {
    const commit = connection.commit.bind(connection);
    cachedConnection.commit = (() => inConnectionOrder(async () => {
      const current = currentSource();
      try {
        await commit();
      } catch (error) {
        // The server may have committed before a connection error was reported.
        await invalidatePending(current, 'commit');
        throw error;
      }
      await invalidatePending(current, 'commit');
      pendingTags.clear();
    })) as oracledb.Connection['commit'];
  }
  if (typeof connection.rollback === 'function') {
    const rollback = connection.rollback.bind(connection);
    cachedConnection.rollback = (() => inConnectionOrder(async () => {
      await rollback();
      pendingTags.clear();
    })) as oracledb.Connection['rollback'];
  }

  cachedConnection.execute = ((
    ...args: unknown[]
  ): Promise<oracledb.Result<unknown>> => inConnectionOrder(async () => {
    const activeSource = currentSource();
    const originalExecute =
      cachedConnection[ORACLE_QUERY_CACHE_ORIGINAL_EXECUTE];
    if (!originalExecute) {
      throw new Error('Oracle query cache original execute missing');
    }

    const sql = typeof args[0] === 'string' ? args[0] : '';
    if (!sql) {
      return await originalExecute(...args);
    }

    const redis = redisOf(activeSource);
    const binds = args.length >= 2 ? args[1] : undefined;
    const options = executeOptionsFromArgs(args);

    const sourcePath = (activeSource.path ?? '').split('?')[0] ?? '';
    const isAiPath = sourcePath === '/api/v2/ai' || sourcePath.startsWith('/api/v2/ai/');
    const isSettingsPath = sourcePath.replace(/\/+$/, '') === '/api/v2/users/me/settings';
    const isStatementPath = /^\/api\/v2\/(?:users\/me\/account-statements|(?:moderation\/(?:appeals|reports|stats|settings|users|content)|reports))(?:\/|$)/.test(sourcePath);
    const isRelationshipPath = /^\/api\/v2\/users(?:\/(?:recommendations|me\/avatar|me\/(?:blocks|mutes)(?:\/[^/]+)?|[^/]+\/(?:followers|following|mutual-following)))?\/*$/.test(sourcePath);
    const isRegistrationPath = sourcePath.replace(/\/+$/, '') === '/api/v2/auth/registration';
    const isDirectMessagePath = /^\/api\/v2\/chat\/direct-conversations(?:\/|$)/.test(sourcePath);
    const isChatChannelPath = /^\/api\/v2\/chat\/(?:groups(?:\/[^/]+\/(?:channels|members))?|channels\/[^/]+(?:\/(?:read-status|mute-status|messages))?|messages\/[^/]+(?:\/(?:pin-status|reactions))?)\/*$/.test(sourcePath);
    const isGroupReadPath = /^\/api\/v2\/(?:groups(?:\/(?:by-slug\/)?[^/]+)?|users\/me\/groups|feed\/groups)\/*$/.test(sourcePath);
    const isGroupMembershipPath = /^\/api\/v2\/(?:groups\/(?:invite-codes\/|invites\/[^/]+\/responses(?:\/|$)|[^/]+\/(?:members|ownership|invites|posts|notification-preference|audit-logs)(?:\/|$))|users\/me\/group-invites\/*$)/.test(sourcePath);
    const isPostLikersPath = /^\/api\/v2\/posts\/[^/]+\/likes\/*$/.test(sourcePath);
    const isPostDraftOrPollPath = /^\/api\/v2\/(?:users\/me\/drafts|posts\/[^/]+\/poll)(?:\/|$)/.test(sourcePath);
    const isPinnedPostPath = /^\/api\/v2\/users\/[^/]+\/pinned-post\/*$/.test(sourcePath);
    const isCredentialPath = /^\/api\/v2\/(?:auth|users\/me)\/(?:passkeys|oauth\/github)(?:\/|$)/.test(sourcePath);
    const isAnalyticsPath = /^\/api\/v2\/(?:posts|users)\/[^/]+\/analytics(?:\/|$)/.test(sourcePath);
    const isFeedbackPath = /^\/api\/v2\/(?:posts(?:\/trending)?|recommendations\/feedback)\/*$/.test(sourcePath);
    let cacheContext: OracleQueryCacheContext | undefined;
    const cacheEligible = pendingTags.size === 0 && !connection.transactionInProgress && !isAiPath && !isSettingsPath && !isStatementPath && !isRelationshipPath && !isRegistrationPath && !isDirectMessagePath && !isChatChannelPath && !isGroupReadPath && !isGroupMembershipPath && !isPostLikersPath && !isPostDraftOrPollPath && !isPinnedPostPath && !isCredentialPath && !isAnalyticsPath && !isFeedbackPath && isCacheableSelectSql(sql);
    if (cacheEligible && redis) {
      try {
        const context = await buildQueryCacheContext(
          activeSource,
          sql,
          binds,
          options,
          redis
        );
        const cached = await readOracleQueryCache(
          activeSource,
          redis,
          context,
          sql
        );
        if (cached) return cached;
        cacheContext = context;
      } catch (error) {
        observeCacheRead('degraded');
        logWarn('oracle-query-cache', {
          event: 'bypass:error',
          requestId: activeSource.requestId ?? 'unknown',
          path: activeSource.path ?? 'oracle',
          sqlHash: hash(normalizeSql(sql)),
          error: serializeLogError(error)
        });
      }
    } else if (cacheEligible && sourcePath !== 'oracle:direct') observeCacheRead('degraded');

    const result = await originalExecute(...args);
    if (isMutatingSql(sql) && !isCacheNeutralMutationSql(sql) && result.rowsAffected !== 0) {
      for (const tag of tagsForSql(sql, activeSource)) pendingTags.add(tag);
    }
    if (pendingTags.size && connection.transactionInProgress === false) {
      await invalidatePending(activeSource, sql);
      pendingTags.clear();
    }
    if (cacheContext && redis && !connection.transactionInProgress) {
      await writeOracleQueryCache(activeSource, redis, cacheContext, sql, result);
    }
    return result;
  })) as oracledb.Connection['execute'];

  cachedConnection[ORACLE_QUERY_CACHE_ATTACHED] = true;
  return connection;
}

export function clearOracleQueryCacheSource(
  connection: oracledb.Connection
): oracledb.Connection {
  const cachedConnection = connection as CachedOracleConnection;
  if (cachedConnection[ORACLE_QUERY_CACHE_ATTACHED]) {
    cachedConnection[ORACLE_QUERY_CACHE_SOURCE] = {
      redis: null,
      requestId: 'direct',
      path: 'oracle:direct'
    };
  }
  return connection;
}

export function attachOracleQueryCache(
  event: H3Event,
  connection: oracledb.Connection
): oracledb.Connection {
  return attachOracleQueryCacheWithSource(
    cacheSourceFromEvent(event),
    connection
  );
}
