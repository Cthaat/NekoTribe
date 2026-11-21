package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"slices"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

var recommendationFeedbackSQL = func() struct {
	Actions                                        []string
	Targets                                        map[string]string
	Schema, LockActor, Save, FeedFilter, FeedOrder string
} {
	var spec struct {
		Actions                                        []string
		Targets                                        map[string]string
		Schema, LockActor, Save, FeedFilter, FeedOrder string
	}
	if err := json.Unmarshal(contracts.RecommendationFeedbackSQL, &spec); err != nil {
		panic("invalid recommendation feedback SQL")
	}
	return spec
}()

var (
	errFeedbackSchema = errors.New("recommendation feedback schema unavailable")
	errFeedbackActor  = errors.New("recommendation feedback account unavailable")
)

type recommendationFeedback struct {
	resourceType   string
	resourceID     int64
	action, reason string
}

func parseRecommendationFeedback(body map[string]any) (recommendationFeedback, bool) {
	_, hasPostID := body["post_id"]
	_, hasFeedback := body["feedback"]
	fields := []string{"resource_type", "resource_id", "action", "reason"}
	kind, _ := body["resource_type"].(string)
	id, _ := body["resource_id"].(float64)
	action, _ := body["action"].(string)
	if hasPostID || hasFeedback {
		fields = []string{"post_id", "feedback", "reason"}
		kind = "post"
		id, _ = body["post_id"].(float64)
		action, _ = body["feedback"].(string)
	}
	for key := range body {
		if !slices.Contains(fields, key) {
			return recommendationFeedback{}, false
		}
	}
	if recommendationFeedbackSQL.Targets[kind] == "" || id < 1 || id > 9007199254740991 || math.Trunc(id) != id ||
		!slices.Contains(recommendationFeedbackSQL.Actions, action) {
		return recommendationFeedback{}, false
	}
	reason := ""
	if raw, provided := body["reason"]; provided {
		var ok bool
		if reason, ok = raw.(string); !ok {
			return recommendationFeedback{}, false
		}
		reason = strings.TrimFunc(reason, jsTrimSpace)
		if len(reason) > 500 || strings.ContainsRune(reason, 0) {
			return recommendationFeedback{}, false
		}
	}
	return recommendationFeedback{kind, int64(id), action, reason}, true
}

func feedbackSchemaReady(ctx context.Context, db publicProfileQueryer) (bool, error) {
	var table string
	err := db.QueryRowContext(ctx, recommendationFeedbackSQL.Schema).Scan(&table)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

type recommendationFeedbackStore interface {
	WriteRecommendationFeedback(context.Context, int64, recommendationFeedback) error
}

func (s OracleSessions) WriteRecommendationFeedback(ctx context.Context, actor int64, input recommendationFeedback) error {
	_, err := statementTransaction(ctx, s.DB, func(tx *sql.Tx) (struct{}, error) {
		var result struct{}
		ready, err := feedbackSchemaReady(ctx, tx)
		if err != nil {
			return result, err
		}
		if !ready {
			return result, errFeedbackSchema
		}
		actorBind, resourceBind := sql.Named("actor_id", actor), sql.Named("resource_id", input.resourceID)
		var found int64
		if err := tx.QueryRowContext(ctx, recommendationFeedbackSQL.LockActor, actorBind).Scan(&found); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return result, errFeedbackActor
			}
			return result, err
		}
		targetBinds := []any{resourceBind}
		if input.resourceType != "tag" {
			targetBinds = append(targetBinds, actorBind)
		}
		if err := tx.QueryRowContext(ctx, recommendationFeedbackSQL.Targets[input.resourceType], targetBinds...).Scan(&found); err != nil {
			return result, err
		}
		rows, err := tx.ExecContext(ctx, recommendationFeedbackSQL.Save, actorBind, resourceBind,
			sql.Named("resource_type", input.resourceType), sql.Named("action", input.action), sql.Named("reason", nullablePostString(input.reason)))
		if err != nil {
			return result, err
		}
		if affected, err := rows.RowsAffected(); err != nil || affected != 1 {
			return result, errSessionStore
		}
		return result, nil
	})
	return err
}

func writeRecommendationFeedback(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repo SessionRepository) {
	viewer, ok := interactionActor(w, r, codec, repo)
	if !ok {
		return
	}
	body, ok := readLoginBody(r)
	if !ok {
		respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
		return
	}
	input, ok := parseRecommendationFeedback(body)
	if !ok {
		respond(w, 400, 40001, "推荐反馈参数错误", nil)
		return
	}
	store, ok := repo.(recommendationFeedbackStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	switch err := store.WriteRecommendationFeedback(r.Context(), viewer, input); {
	case err == nil:
		respond(w, 200, 200, "success", map[string]bool{"accepted": true})
	case errors.Is(err, errFeedbackSchema):
		respond(w, 503, 50301, "服务暂不可用，请稍后重试。", nil)
	case errors.Is(err, errFeedbackActor):
		respond(w, 403, 40301, "账号不可用", nil)
	case errors.Is(err, sql.ErrNoRows):
		respond(w, 404, 40401, "反馈目标不存在", nil)
	default:
		respond(w, 500, 50001, "服务器内部错误", nil)
	}
}
