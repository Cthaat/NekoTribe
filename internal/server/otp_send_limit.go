package server

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

// OTPSendLimiter reserves one send or returns the number of seconds to wait.
type OTPSendLimiter interface {
	ReserveOTP(context.Context, string) (int64, error)
}

type RedisOTPSendLimiter struct {
	client *redis.Client
}

var errOTPSendLimit = errors.New("OTP rate limit unavailable")

func NewRedisOTPSendLimiter(lookup func(string) (string, bool)) (*RedisOTPSendLimiter, error) {
	options, err := redisSourceOptions(lookup)
	if err != nil {
		return nil, errOTPSendLimit
	}
	options.ContextTimeoutEnabled = true
	return &RedisOTPSendLimiter{client: redis.NewClient(options)}, nil
}

func (l *RedisOTPSendLimiter) Close() error {
	return l.client.Close()
}

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
return 0`

func otpSendKeys(account string) []string {
	normalized := strings.Map(func(c rune) rune {
		if c >= 'A' && c <= 'Z' {
			return c + ('a' - 'A')
		}
		return c
	}, account)
	prefix := fmt.Sprintf("neko:auth:otp-send:v1:{%x}", sha256.Sum256([]byte(normalized)))
	return []string{prefix + ":cooldown", prefix + ":window"}
}

func (l *RedisOTPSendLimiter) ReserveOTP(ctx context.Context, account string) (int64, error) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	retry, err := l.client.Eval(ctx, otpSendLimitLua, otpSendKeys(account)).Int64()
	if err != nil || retry < 0 || retry > 3600 {
		return 0, errOTPSendLimit
	}
	return retry, nil
}
