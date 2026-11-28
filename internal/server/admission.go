package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/netip"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// One EVAL shares the first admission's deadline across all backend instances.
const admissionLua = `local used = redis.call('GET', KEYS[1])
if not used then
  redis.call('SET', KEYS[1], 1, 'PX', ARGV[2])
  return {1, tonumber(ARGV[1])-1, tonumber(ARGV[2])}
end
local ttl = redis.call('PTTL', KEYS[1])
if ttl < 0 then return redis.error_reply('invalid admission expiry') end
if tonumber(used) >= tonumber(ARGV[1]) then return {0, 0, ttl} end
local count = redis.call('INCR', KEYS[1])
return {1, tonumber(ARGV[1])-count, ttl}`

type admissionTier struct {
	name           string
	limit, seconds int64
}
type admissionResult struct {
	admitted         bool
	remaining, ttlMS int64
}
type admissionStore interface {
	admit(context.Context, string, admissionTier) (admissionResult, error)
}

func (s *RedisOTPSendLimiter) admit(ctx context.Context, key string, tier admissionTier) (admissionResult, error) {
	ctx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	values, err := s.client.Eval(ctx, admissionLua, []string{key}, tier.limit, tier.seconds*1000).Int64Slice()
	if err != nil {
		return admissionResult{}, err
	}
	if len(values) != 3 || (values[0] != 0 && values[0] != 1) || values[1] < 0 || values[1] >= tier.limit || values[2] < 0 {
		return admissionResult{}, errors.New("invalid admission reply")
	}
	return admissionResult{values[0] == 1, values[1], values[2]}, nil
}

var generationRoute = regexp.MustCompile(`^ai/conversations/[^/]+/(generate|knowledge-generate|group-generate|moderation-generate)$`)

func classifyAdmission(method, path string) admissionTier {
	sessions := path == "auth/sessions" || strings.HasPrefix(path, "auth/sessions/")
	authException := sessions && (method == "GET" || method == "DELETE") || path == "auth/tokens/current" && method == "DELETE"
	switch {
	case strings.HasPrefix(path, "auth/") && !authException,
		method == "PATCH" && path == "users/me/email",
		method == "POST" && (path == "users/me/two-factor/setup" || path == "users/me/two-factor/confirm"),
		method == "DELETE" && path == "users/me/two-factor":
		return admissionTier{"auth", 10, 60}
	case method == "POST" && (generationRoute.MatchString(path) || path == "ai/media/describe" || path == "users/me/ai-provider/test"):
		return admissionTier{"ai", 10, 60}
	case method == "GET" && path == "users/me/export", method == "POST" && (path == "media" || path == "media/private"), method == "PUT" && path == "users/me/avatar":
		return admissionTier{"transfer", 10, 60}
	case method == "GET" || method == "HEAD":
		return admissionTier{"read", 100, 10}
	default:
		return admissionTier{"write", 40, 10}
	}
}

func canonicalClientIP(raw string) string {
	ip, err := netip.ParseAddr(raw)
	if err != nil || ip.Zone() != "" {
		return "unknown"
	}
	return ip.Unmap().String()
}

func rejectAtAdmission(w http.ResponseWriter, r *http.Request, config RefreshConfig, path string) bool {
	if config.Admission == nil {
		return false
	}
	tier := classifyAdmission(r.Method, strings.TrimRight(path, "/"))
	key := "neko:v2:admission:1:" + tier.name + ":" + canonicalClientIP(requestIP(r, config.TrustProxy))
	result, err := config.Admission.admit(r.Context(), key, tier)
	if err != nil {
		return false
	}
	delay := strconv.FormatInt(max(1, (result.ttlMS+999)/1000), 10)
	w.Header().Set("RateLimit-Limit", strconv.FormatInt(tier.limit, 10))
	w.Header().Set("RateLimit-Remaining", strconv.FormatInt(result.remaining, 10))
	w.Header().Set("RateLimit-Reset", delay)
	if result.admitted {
		return false
	}
	w.Header().Set("Retry-After", delay)
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusTooManyRequests)
	if r.Method != http.MethodHead {
		const msg = "请求过于频繁，请稍后重试"
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"error": true, "url": r.URL.EscapedPath(), "statusCode": 429, "statusMessage": msg, "message": msg,
			"data": map[string]interface{}{"code": 42901, "message": msg, "data": nil, "meta": nil},
		})
	}
	return true
}
