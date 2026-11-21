package server

import (
	"context"
	"crypto/sha256"
	"fmt"
	"net/http"
	"time"
)

// OTPAttemptLimiter atomically reserves a code comparison for an issued OTP.
type OTPAttemptLimiter interface {
	ReserveOTPAttempt(context.Context, string) (bool, error)
}

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
return 1`

func otpAttemptKey(verificationID string) string {
	return fmt.Sprintf("neko:auth:otp-attempt:v1:%x", sha256.Sum256([]byte(verificationID)))
}

func (l *RedisOTPSendLimiter) ReserveOTPAttempt(ctx context.Context, verificationID string) (bool, error) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	result, err := l.client.Eval(ctx, otpAttemptLimitLua, []string{otpAttemptKey(verificationID)}).Int64()
	if err != nil || (result != 0 && result != 1) {
		return false, errOTPSendLimit
	}
	return result == 1, nil
}

func requireOTPAttempt(w http.ResponseWriter, r *http.Request, limiter OTPAttemptLimiter, verificationID string) bool {
	if limiter == nil {
		respond(w, 503, 50301, "服务暂不可用，请稍后重试。", nil)
		return false
	}
	allowed, err := limiter.ReserveOTPAttempt(r.Context(), verificationID)
	if err != nil {
		respond(w, 503, 50301, "服务暂不可用，请稍后重试。", nil)
		return false
	}
	if !allowed {
		respond(w, 429, 42901, "验证码尝试次数已用完，请重新获取验证码", nil)
	}
	return allowed
}
