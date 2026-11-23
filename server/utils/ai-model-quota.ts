import { createError, setResponseHeader, type H3Event } from 'h3';
import type Redis from 'ioredis';
import contract from '../../specifications/requirements/ai-model-quota.json';
import { v2Throw } from '~/server/utils/v2';

export class AiQuotaError extends Error {
  constructor(readonly retryAfter: number | null) {
    super(retryAfter === null ? 'AI quota unavailable' : 'AI quota exhausted');
  }
}

function readLimit(value: string | undefined, fallback: number): number {
  if (value === undefined) return fallback;
  if (!/^[1-9][0-9]{0,5}$/.test(value)) throw new AiQuotaError(null);
  const limit = Number(value);
  if (limit < 2 || limit > contract.maxLimit) throw new AiQuotaError(null);
  return limit;
}

async function readAiUsage(redis: Pick<Redis, 'get'> | undefined, key: string, limit: string | undefined, fallback: number) {
  const usage = { used_units: null as number | null, limit_units: null as number | null,
    window_seconds: contract.windowMilliseconds / 1000 };
  try {
    usage.limit_units = readLimit(limit, fallback);
  } catch { /* Invalid deployment limit is represented as unavailable. */ }
  try {
    if (redis) {
      const raw = await redis.get(key);
      const units = Number(raw);
      if (Number.isInteger(units) && units >= 0 && units <= contract.maxLimit) usage.used_units = units;
    }
  } catch { /* Redis failure leaves usage unavailable. */ }
  return usage;
}

export function readAiAccountQuota(redis: Pick<Redis, 'get'> | undefined, actor: number) {
  return readAiUsage(redis, `${contract.keyPrefix}:actor:${actor}`, process.env.AI_QUOTA_ACTOR_PER_MINUTE, contract.actorLimit);
}

export function readAiServiceQuota(redis: Pick<Redis, 'get'> | undefined) {
  return readAiUsage(redis, `${contract.keyPrefix}:service`, process.env.AI_QUOTA_SERVICE_PER_MINUTE, contract.serviceLimit);
}

export async function reserveAiModelQuota(
  redis: Pick<Redis, 'eval'> | undefined,
  actor: number,
  cost: 1 | 2,
  environment = process.env,
): Promise<number> {
  if (!redis || !Number.isSafeInteger(actor) || actor < 1 || (cost !== 1 && cost !== 2)) {
    throw new AiQuotaError(null);
  }
  const actorLimit = readLimit(environment.AI_QUOTA_ACTOR_PER_MINUTE, contract.actorLimit);
  const serviceLimit = readLimit(environment.AI_QUOTA_SERVICE_PER_MINUTE, contract.serviceLimit);
  let retry: unknown;
  try {
    retry = await redis.eval(contract.lua, 2, `${contract.keyPrefix}:actor:${actor}`, `${contract.keyPrefix}:service`,
      cost, actorLimit, serviceLimit, contract.windowMilliseconds, contract.maxLimit);
  } catch {
    throw new AiQuotaError(null);
  }
  if (typeof retry !== 'number' || !Number.isSafeInteger(retry) || retry < 0 || retry > contract.windowMilliseconds / 1000) {
    throw new AiQuotaError(null);
  }
  return retry;
}

export async function requireAiModelQuota(event: H3Event, actor: number, cost: 1 | 2): Promise<void> {
  const retry = await reserveAiModelQuota(event.context.aiQuotaRedis, actor, cost);
  if (retry > 0) throw new AiQuotaError(retry);
}

export function throwAiQuotaResponse(event: H3Event, error: AiQuotaError): never {
  if (error.retryAfter !== null) {
    setResponseHeader(event, 'Retry-After', error.retryAfter);
    v2Throw(429, 'AI 请求额度已用完，请稍后重试', 42901);
  }
  throw createError({
    statusCode: 503,
    statusMessage: 'Service temporarily unavailable',
    data: {code:50301,message:'服务暂不可用，请稍后重试。',data:null,meta:null},
  });
}
