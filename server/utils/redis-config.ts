import { useRuntimeConfig } from '#imports';
import type { RedisOptions } from 'ioredis';

function pickRuntimeValue(
  nuxtKey: string,
  legacyKey: string,
  fallback?: string
): string | undefined {
  const runtimeValue =
    process.env[nuxtKey] ?? process.env[legacyKey];

  if (typeof runtimeValue === 'string' && runtimeValue) {
    return runtimeValue;
  }

  if (typeof fallback === 'string' && fallback) {
    return fallback;
  }

  return undefined;
}

function parseInteger(
  value: string | undefined,
  defaultValue: number
): number {
  const parsed = Number.parseInt(value ?? '', 10);
  return Number.isFinite(parsed) ? parsed : defaultValue;
}

function applyRedisUrl(
  redisUrl: string,
  options: RedisOptions
) {
  const normalizedUrl = redisUrl.includes('://')
    ? redisUrl
    : `redis://${redisUrl}`;

  try {
    const parsedUrl = new URL(normalizedUrl);

    if (parsedUrl.hostname) {
      options.host = parsedUrl.hostname;
    }

    if (parsedUrl.port) {
      options.port = parseInteger(parsedUrl.port, 6379);
    }

    const db = parsedUrl.pathname.replace(/^\/+/, '');
    if (db) {
      options.db = parseInteger(db, 0);
    }

    if (parsedUrl.username) {
      options.username = decodeURIComponent(
        parsedUrl.username
      );
    }

    if (parsedUrl.password) {
      options.password = decodeURIComponent(
        parsedUrl.password
      );
    }
  } catch {
    options.host = redisUrl;
  }
}

export function resolveRedisOptions(): RedisOptions {
  const runtimeConfig = useRuntimeConfig();
  const redisUrl = pickRuntimeValue(
    'NUXT_REDIS_URL',
    'REDIS_URL',
    runtimeConfig.redisUrl
  );
  const redisHost = pickRuntimeValue(
    'NUXT_REDIS_HOST',
    'REDIS_HOST',
    runtimeConfig.redisHost
  );
  const redisPort = pickRuntimeValue(
    'NUXT_REDIS_PORT',
    'REDIS_PORT',
    runtimeConfig.redisPort
  );
  const redisDb = pickRuntimeValue(
    'NUXT_REDIS_DB',
    'REDIS_DB',
    runtimeConfig.redisDb
  );
  const redisPassword = pickRuntimeValue(
    'NUXT_REDIS_PASSWORD',
    'REDIS_PASSWORD',
    runtimeConfig.redisPassword
  );

  const options: RedisOptions = {};

  if (redisUrl) {
    applyRedisUrl(redisUrl, options);
  }

  options.host = redisHost || options.host || '127.0.0.1';
  options.port = parseInteger(
    redisPort,
    options.port ?? 6379
  );
  options.db = parseInteger(redisDb, options.db ?? 0);

  if (redisPassword) {
    options.password = redisPassword;
  }

  options.connectTimeout = 1500;
  options.maxRetriesPerRequest = 1;
  options.enableOfflineQueue = false;
  options.retryStrategy = times =>
    times > 1 ? null : Math.min(times * 200, 1000);

  return options;
}
