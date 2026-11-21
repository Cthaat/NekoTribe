package server

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"time"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/redis/go-redis/v9"
)

type aiQuotaDefinition struct {
	WindowMilliseconds int64
	ActorLimit         int64
	ServiceLimit       int64
	MaxLimit           int64
	KeyPrefix          string
	Lua                string
}

var aiQuotaContract = func() aiQuotaDefinition {
	var contract aiQuotaDefinition
	if json.Unmarshal(contracts.AIModelQuota, &contract) != nil || contract.KeyPrefix == "" || contract.Lua == "" {
		panic("invalid AI quota contract")
	}
	return contract
}()

var errAIQuotaUnavailable = errors.New("AI quota unavailable")

type aiQuotaExceeded struct{ retryAfter int64 }

func (aiQuotaExceeded) Error() string { return "AI quota exhausted" }

type AIModelQuotaLimiter interface {
	ReserveAIModelQuota(context.Context, int64, int64) (int64, error)
}

type RedisAIModelQuota struct {
	client     *redis.Client
	actorLimit int64
	totalLimit int64
}

func NewRedisAIModelQuota(lookup func(string) (string, bool)) (*RedisAIModelQuota, error) {
	options, err := redisSourceOptions(lookup)
	if err != nil {
		return nil, errAIQuotaUnavailable
	}
	options.ContextTimeoutEnabled = true
	options.MaxRetries = -1
	options.DialTimeout = 2 * time.Second
	return &RedisAIModelQuota{
		client:     redis.NewClient(options),
		actorLimit: aiQuotaLimit(lookup, "AI_QUOTA_ACTOR_PER_MINUTE", aiQuotaContract.ActorLimit),
		totalLimit: aiQuotaLimit(lookup, "AI_QUOTA_SERVICE_PER_MINUTE", aiQuotaContract.ServiceLimit),
	}, nil
}

func aiQuotaLimit(lookup func(string) (string, bool), name string, fallback int64) int64 {
	value, provided := lookup(name)
	if !provided {
		return fallback
	}
	n, err := strconv.ParseInt(value, 10, 64)
	if err != nil || n < 2 || n > aiQuotaContract.MaxLimit || strconv.FormatInt(n, 10) != value {
		return 0
	}
	return n
}

func (l *RedisAIModelQuota) Close() error { return l.client.Close() }

func (l *RedisAIModelQuota) ReserveAIModelQuota(ctx context.Context, actor, cost int64) (int64, error) {
	if actor < 1 || actor > 9007199254740991 || cost < 1 || cost > 2 || l.actorLimit == 0 || l.totalLimit == 0 {
		return 0, errAIQuotaUnavailable
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	prefix := aiQuotaContract.KeyPrefix
	keys := []string{prefix + ":actor:" + strconv.FormatInt(actor, 10), prefix + ":service"}
	retry, err := l.client.Eval(ctx, aiQuotaContract.Lua, keys,
		cost, l.actorLimit, l.totalLimit, aiQuotaContract.WindowMilliseconds, aiQuotaContract.MaxLimit).Int64()
	if err != nil || retry < 0 || retry > aiQuotaContract.WindowMilliseconds/1000 {
		return 0, errAIQuotaUnavailable
	}
	return retry, nil
}

func requireAIModelQuota(ctx context.Context, limiter AIModelQuotaLimiter, actor, cost int64) error {
	if limiter == nil || ctx.Err() != nil {
		return errAIQuotaUnavailable
	}
	retry, err := limiter.ReserveAIModelQuota(ctx, actor, cost)
	if err != nil || ctx.Err() != nil || retry < 0 || retry > aiQuotaContract.WindowMilliseconds/1000 {
		return errAIQuotaUnavailable
	}
	if retry > 0 {
		return aiQuotaExceeded{retryAfter: retry}
	}
	return nil
}
