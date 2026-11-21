import { useRuntimeConfig } from '#imports';
import { isIP } from 'node:net';
import type { RedisOptions } from 'ioredis';

function pickRuntimeValue(
  nuxtKey: string,
  legacyKey: string,
  fallback?: string
): string | undefined {
  const runtimeValue =
    process.env[nuxtKey] ?? process.env[legacyKey];

  if (typeof runtimeValue === 'string') {
    return runtimeValue || undefined;
  }

  if (typeof fallback === 'string' && fallback) {
    return fallback;
  }

  return undefined;
}

function parseInteger(
  value: string | undefined,
  defaultValue: number,
  minimum: number
): number {
  if (!value) return defaultValue;
  const parsed = Number(value);
  if (!/^\d+$/.test(value) || !Number.isSafeInteger(parsed) || parsed < minimum || parsed > 65535) {
    throw Error('Invalid Redis configuration');
  }
  return parsed;
}

function unbracketIPv6(host: string): string {
  const address = host.slice(1, -1);
  return host.startsWith('[') && host.endsWith(']') && isIP(address) === 6 ? address : host;
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
    if (!['redis:', 'rediss:'].includes(parsedUrl.protocol) || !parsedUrl.hostname || parsedUrl.hash) {
      throw Error('Invalid Redis configuration');
    }
    options.host = unbracketIPv6(parsedUrl.hostname);

    if (parsedUrl.port) {
      options.port = parseInteger(parsedUrl.port, 6379, 1);
    }

    const db = parsedUrl.pathname.replace(/^\/+/, '');
    if (db) {
      options.db = parseInteger(db, 0, 0);
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
    if (parsedUrl.protocol === 'rediss:') options.tls = { minVersion: 'TLSv1.2' };
  } catch {
    throw Error('Invalid Redis configuration');
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

  options.host = unbracketIPv6(redisHost || options.host || '127.0.0.1');
  if (/[\s/@?#]/.test(options.host)) throw Error('Invalid Redis configuration');
  if (options.tls && !isIP(options.host)) options.tls.servername = options.host;
  options.port = parseInteger(
    redisPort,
    options.port ?? 6379,
    1
  );
  options.db = parseInteger(redisDb, options.db ?? 0, 0);

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
