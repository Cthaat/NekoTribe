import { createHash } from 'node:crypto';
import { createError, type H3Event } from 'h3';
import { v2Throw } from './v2';

const otpAttemptLimitLua = `local ttl = redis.call('PTTL', KEYS[1])
if ttl == -2 then
  redis.call('SET', KEYS[1], '1', 'EX', 3600)
  return 1
end
local count = tonumber(redis.call('GET', KEYS[1]))
if ttl < 0 or not count or count < 1 or count > 5 or count ~= math.floor(count) then
  return redis.error_reply('invalid OTP attempt limit state')
end
if count == 5 then return 0 end
redis.call('INCR', KEYS[1])
return 1`;

export function otpAttemptKey(verificationId: string): string {
  const hash = createHash('sha256').update(verificationId, 'utf8').digest('hex');
  return `neko:auth:otp-attempt:v1:${hash}`;
}

export async function requireOtpAttempt(event: H3Event, verificationId: string): Promise<void> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  let allowed: unknown;
  try {
    const redis = event.context.redis;
    if (redis) {
      const deadline = new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error('OTP attempt limit unavailable')), 2000);
      });
      allowed = await Promise.race([redis.eval(otpAttemptLimitLua, 1, otpAttemptKey(verificationId)), deadline]);
    }
  } catch {
    allowed = undefined;
  } finally {
    clearTimeout(timer);
  }
  if (allowed === 0) v2Throw(429, '验证码尝试次数已用完，请重新获取验证码');
  if (allowed !== 1) {
    throw createError({
      statusCode: 503,
      statusMessage: 'Service temporarily unavailable',
      data: { code: 50301, message: '服务暂不可用，请稍后重试。', data: null, meta: null }
    });
  }
}
