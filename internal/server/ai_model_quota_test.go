package server

import "context"

type singleCallAIQuota struct{}

func (singleCallAIQuota) ReserveAIModelQuota(_ context.Context, actor, cost int64) (int64, error) {
	if actor < 1 || cost != 1 {
		return 0, errAIQuotaUnavailable
	}
	return 0, nil
}
