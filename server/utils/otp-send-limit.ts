import { createHash } from 'node:crypto';
import type Redis from 'ioredis';

const otpSendLimitLua = `local cooldown = redis.call('PTTL', KEYS[1])
local window = redis.call('PTTL', KEYS[2])
local count = tonumber(redis.call('GET', KEYS[2]) or '0')
if cooldown == -1 or window == -1 or not count or count < 0 or count > 5 or count ~= math.floor(count) then
  return redis.error_reply('invalid OTP rate limit state')
end
local retry = cooldown
if count >= 5 then
  retry = math.max(retry, window)
end
if retry >= 0 then
  return math.max(1, math.ceil(retry / 1000))
end
if window == -2 then
  redis.call('SET', KEYS[2], '1', 'EX', 3600)
else
  redis.call('INCR', KEYS[2])
end
redis.call('SET', KEYS[1], '1', 'EX', 60)
return 0`;

export function otpSendKeys(account: string): [string, string] {
  const normalized = account.replace(/[A-Z]/g, character => character.toLowerCase());
  const hash = createHash('sha256').update(normalized, 'utf8').digest('hex');
  const prefix = `neko:auth:otp-send:v1:{${hash}}`;
  return [`${prefix}:cooldown`, `${prefix}:window`];
}

export async function reserveOtpSend(redis: Pick<Redis, 'eval'> | undefined, account: string): Promise<number> {
  if (!redis) throw new Error('OTP rate limit unavailable');
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error('OTP rate limit unavailable')), 2000);
    });
    const retry = await Promise.race([redis.eval(otpSendLimitLua, 2, ...otpSendKeys(account)), timeout]);
    if (typeof retry !== 'number' || !Number.isSafeInteger(retry) || retry < 0 || retry > 3600) {
      throw new Error('OTP rate limit unavailable');
    }
    return retry;
  } finally {
    clearTimeout(timer);
  }
}
