package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type postActionSpec struct {
	Status, Report string
	Deleted        *int64
}

type postActionsContract struct {
	MaxPosts, MaxReasonBytes, MaxNoteBytes int
	Actions                                map[string]postActionSpec
	SQL                                    map[string]string
}

var moderationPostActions = func() postActionsContract {
	var spec postActionsContract
	if err := json.Unmarshal(contracts.ModerationPostActionsContract, &spec); err != nil {
		panic("invalid moderation post actions contract")
	}
	return spec
}()

var errPostActionMissing = errors.New("moderation post missing")
var errPostActionNote = errors.New("moderation note required")
var errPostActionClaimDisabled = errors.New("moderation claiming disabled")
var errPostActionClaimed = errors.New("moderation case assigned to another reviewer")

type postActionInput struct {
	IDs                  []int64
	Action, Reason, Note string
	Bulk                 bool
}

type postActionResult struct {
	Item  contentQueueItem
	Count int
}

type moderationPostActionStore interface {
	ModerationAllowed(context.Context, int64, moderationPolicy) (bool, error)
	ModeratePosts(context.Context, int64, postActionInput, StorageURLPolicy) (postActionResult, error)
}

func moderationTargetID(input any) int64 {
	switch v := input.(type) {
	case float64:
		if v > 0 && v <= 9007199254740991 && math.Trunc(v) == v {
			return int64(v)
		}
	case string:
		if publicID.MatchString(v) {
			id, err := strconv.ParseInt(v, 10, 64)
			if err == nil && id <= 9007199254740991 {
				return id
			}
		}
	}
	return 0
}

func parsePostAction(body map[string]any, raw string, bulk bool) (postActionInput, string) {
	input := postActionInput{Bulk: bulk, Action: "flag"}
	spec := moderationPostActions
	if val, has := body["action"]; has {
		action, _ := val.(string)
		input.Action = strings.TrimFunc(action, jsTrimSpace)
	}
	_, valid := spec.Actions[input.Action]
	if !valid || bulk && (input.Action == "claim" || input.Action == "release") {
		return input, "action 参数错误"
	}
	for _, field := range []struct {
		name string
		max  int
		dest *string
	}{
		{"note", spec.MaxNoteBytes, &input.Note}, {"reason", spec.MaxReasonBytes, &input.Reason},
	} {
		if body[field.name] == nil {
			continue
		}
		val, ok := body[field.name].(string)
		val = strings.TrimFunc(val, jsTrimSpace)
		if !ok || len(val) > field.max || strings.ContainsRune(val, 0) {
			return input, field.name + " 参数错误"
		}
		*field.dest = val
	}
	values := []any{raw}
	if bulk {
		var ok bool
		values, ok = body["post_ids"].([]any)
		if !ok || len(values) == 0 || len(values) > spec.MaxPosts {
			return input, "post_ids 参数错误"
		}
	}
	for _, value := range values {
		id := moderationTargetID(value)
		if id == 0 {
			return input, "post_id 参数错误"
		}
		input.IDs = append(input.IDs, id)
	}
	slices.Sort(input.IDs)
	input.IDs = slices.Compact(input.IDs)
	return input, ""
}

func postActionSettings(ctx context.Context, tx *sql.Tx, input postActionInput) error {
	rows, err := tx.QueryContext(ctx, moderationPostActions.SQL["settings"])
	if err != nil {
		return err
	}
	defer rows.Close()
	enabled := map[string]bool{"allow_moderator_claim": true, "require_note_on_reject": true}
	for rows.Next() {
		var key string
		var val sql.NullString
		if err := rows.Scan(&key, &val); err != nil {
			return err
		}
		value := strings.ToLower(strings.TrimFunc(val.String, jsTrimSpace))
		enabled[key] = value != "0" && value != "false"
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if (input.Action == "claim" || input.Action == "release") && !enabled["allow_moderator_claim"] {
		return errPostActionClaimDisabled
	}
	if (input.Action == "reject" || input.Action == "remove") && input.Note == "" && enabled["require_note_on_reject"] {
		return errPostActionNote
	}
	return nil
}

func execModerationRow(ctx context.Context, tx *sql.Tx, query string, args ...any) error {
	result, err := tx.ExecContext(ctx, query, args...)
	if err != nil {
		return err
	}
	if count, err := result.RowsAffected(); err != nil || count != 1 {
		return errSessionStore
	}
	return nil
}

func applyPostAction(ctx context.Context, tx *sql.Tx, viewer, id int64, input postActionInput) error {
	spec := moderationPostActions
	action := spec.Actions[input.Action]
	key, actor := sql.Named("post_id", id), sql.Named("viewer_id", viewer)
	var caseID int64
	var assigned sql.NullInt64
	err := tx.QueryRowContext(ctx, spec.SQL["case"], key).Scan(&caseID, &assigned)
	if errors.Is(err, sql.ErrNoRows) {
		if err := execModerationRow(ctx, tx, spec.SQL["create"], key); err != nil {
			return err
		}
		err = tx.QueryRowContext(ctx, spec.SQL["case"], key).Scan(&caseID, &assigned)
	}
	if err != nil || caseID <= 0 {
		return errSessionStore
	}
	if (input.Action == "claim" || input.Action == "release") && assigned.Valid && assigned.Int64 != viewer {
		return errPostActionClaimed
	}
	if action.Deleted != nil {
		if err := execModerationRow(ctx, tx, spec.SQL["updatePost"], key, sql.Named("deleted", *action.Deleted)); err != nil {
			return err
		}
	}
	cid, act := sql.Named("case_id", caseID), sql.Named("action", input.Action)
	if err := execModerationRow(ctx, tx, spec.SQL["updateCase"], cid, actor, act, sql.Named("status", action.Status)); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, spec.SQL["updateReports"], key, actor, sql.Named("status", action.Report)); err != nil {
		return err
	}
	return execModerationRow(ctx, tx, spec.SQL["audit"], cid, key, act, actor, sql.Named("reason", nullablePostString(input.Reason)), sql.Named("note", nullablePostString(input.Note)))
}

func (s OracleSessions) ModeratePosts(ctx context.Context, viewer int64, input postActionInput, storage StorageURLPolicy) (postActionResult, error) {
	return statementTransaction(ctx, s.DB, func(tx *sql.Tx) (postActionResult, error) {
		var out postActionResult
		if err := postActionSettings(ctx, tx, input); err != nil {
			return out, err
		}
		for _, id := range input.IDs {
			var locked int64
			err := tx.QueryRowContext(ctx, moderationPostActions.SQL["post"], sql.Named("post_id", id)).Scan(&locked)
			if errors.Is(err, sql.ErrNoRows) {
				return out, errPostActionMissing
			}
			if err != nil {
				return out, err
			}
		}
		for _, id := range input.IDs {
			if err := applyPostAction(ctx, tx, viewer, id, input); err != nil {
				return out, err
			}
		}
		out.Count = len(input.IDs)
		if !input.Bulk {
			items, _, err := readModerationContent(ctx, tx, viewer, sql.NullInt64{Int64: input.IDs[0], Valid: true},
				contentQueueFilters{Date: "all", Sort: "newest"}, SessionPage{Start: 1, End: 1}, storage)
			if err != nil || len(items) != 1 {
				return out, errSessionStore
			}
			out.Item = items[0]
		}
		return out, nil
	})
}

func handleModerationPostActions(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repo SessionRepository, config RefreshConfig) bool {
	const base = "/api/v2/moderation/content/"
	path := r.URL.EscapedPath()
	if r.Method != http.MethodPost || !strings.HasPrefix(path, base) {
		return false
	}
	suffix := strings.TrimPrefix(path, base)
	bulk := suffix == "bulk-actions"
	raw, single := strings.CutSuffix(suffix, "/actions")
	if !bulk && (!single || raw == "" || strings.Contains(raw, "/")) {
		return false
	}
	viewer, ok := interactionActor(w, r, codec, repo)
	if !ok {
		return true
	}
	serverError := func() { respond(w, 500, 50001, "服务器内部错误", nil) }
	store, ok := repo.(moderationPostActionStore)
	if !ok {
		serverError()
		return true
	}
	ctx := r.Context()
	allowed, err := store.ModerationAllowed(ctx, viewer, conversationPolicy(config.ModerationAllowAll, config.ModerationAdminAccounts))
	if err != nil {
		serverError()
		return true
	}
	if !allowed {
		respond(w, 403, 40301, "需要审核权限", nil)
		return true
	}
	body, ok := readLoginBody(r)
	if !ok {
		respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
		return true
	}
	decoded, _ := url.PathUnescape(raw)
	input, invalid := parsePostAction(body, decoded, bulk)
	if invalid != "" {
		respond(w, 400, 40001, invalid, nil)
		return true
	}
	result, err := store.ModeratePosts(ctx, viewer, input, config.Storage)
	switch {
	case errors.Is(err, errPostActionMissing):
		respond(w, 404, 40401, "帖子不存在", nil)
	case errors.Is(err, errPostActionNote):
		respond(w, 400, 40001, "请填写审核备注", nil)
	case errors.Is(err, errPostActionClaimDisabled):
		respond(w, 403, 40301, "审核领取已关闭", nil)
	case errors.Is(err, errPostActionClaimed):
		respond(w, 409, 40901, "案件由其他审核员领取", nil)
	case err != nil:
		serverError()
	case bulk:
		respond(w, 200, 200, "bulk moderation action applied", map[string]int{"processed_count": result.Count})
	default:
		respond(w, 200, 200, "moderation action applied", result.Item)
	}
	return true
}
