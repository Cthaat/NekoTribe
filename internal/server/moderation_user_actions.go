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

type userActionsSpec struct {
	Actions                                []string
	MaxDurationHours, DefaultDurationHours int64
	MaxNoteBytes, MaxReasonBytes           int
	SQL                                    map[string]string
}

var moderationUserActions = func() userActionsSpec {
	var spec userActionsSpec
	if err := json.Unmarshal(contracts.ModerationUserActionsContract, &spec); err != nil {
		panic("invalid moderation user actions contract")
	}
	return spec
}()

var errModerationUserMissing = errors.New("moderation user missing")
var errModerationUserState = errors.New("moderation account status conflict")

type userActionInput struct {
	ID                   int64
	Action, Note, Reason string
	Hours                *int64
}

type moderationUserActionStore interface {
	ModerationAllowed(context.Context, int64, moderationPolicy) (bool, error)
	ModerateUser(context.Context, int64, userActionInput, StorageURLPolicy) (moderationQueueUser, error)
}

func moderationHours(input any) (int64, bool) {
	max := moderationUserActions.MaxDurationHours
	switch v := input.(type) {
	case float64:
		if v >= 0 && v <= float64(max) && math.Trunc(v) == v {
			return int64(v), true
		}
	case string:
		raw := strings.TrimFunc(v, jsTrimSpace)
		if raw == "" || strings.IndexFunc(raw, func(r rune) bool { return r < '0' || r > '9' }) >= 0 {
			return 0, false
		}
		raw = strings.TrimLeft(raw, "0")
		if raw == "" {
			return 0, true
		}
		n, err := strconv.ParseInt(raw, 10, 64)
		if err == nil && n <= max {
			return n, true
		}
	}
	return 0, false
}

func parseUserAction(body map[string]any, id int64) (userActionInput, string) {
	input := userActionInput{ID: id}
	spec := moderationUserActions
	action, _ := body["action"].(string)
	input.Action = strings.TrimFunc(action, jsTrimSpace)
	if !slices.Contains(spec.Actions, input.Action) {
		return input, "action 参数错误"
	}
	for _, field := range []struct {
		name string
		max  int
		dest *string
	}{
		{"reason", spec.MaxReasonBytes, &input.Reason}, {"note", spec.MaxNoteBytes, &input.Note},
	} {
		if body[field.name] == nil {
			continue
		}
		value, ok := body[field.name].(string)
		value = strings.TrimFunc(value, jsTrimSpace)
		if !ok || len(value) > field.max || strings.ContainsRune(value, 0) {
			return input, field.name + " 参数错误"
		}
		*field.dest = value
	}
	if raw, present := body["duration_hours"]; present && (input.Action == "ban" || input.Action == "mute") {
		h, ok := moderationHours(raw)
		if !ok || input.Action == "mute" && h == 0 {
			return input, "duration_hours 参数错误"
		}
		input.Hours = &h
	}
	return input, ""
}

func (s OracleSessions) ModerateUser(ctx context.Context, viewer int64, input userActionInput, storage StorageURLPolicy) (moderationQueueUser, error) {
	return statementTransaction(ctx, s.DB, func(tx *sql.Tx) (moderationQueueUser, error) {
		var item moderationQueueUser
		spec := moderationUserActions
		key, actor := sql.Named("user_id", input.ID), sql.Named("viewer_id", viewer)
		var actual, active int64
		var state string
		err := tx.QueryRowContext(ctx, spec.SQL["lock"], key).Scan(&actual, &state, &active)
		if errors.Is(err, sql.ErrNoRows) {
			return item, errModerationUserMissing
		}
		if err != nil {
			return item, err
		}
		banState := state == "suspended" && active == 0
		if (input.Action == "ban" || input.Action == "unban") && !(state == "active" && active == 1) {
			if !banState {
				return item, errModerationUserState
			}
			var found int64
			err := tx.QueryRowContext(ctx, spec.SQL["banHistory"], key).Scan(&found)
			if errors.Is(err, sql.ErrNoRows) {
				return item, errModerationUserState
			}
			if err != nil {
				return item, err
			}
		}
		adding := input.Action == "ban" || input.Action == "mute"
		if adding && input.Hours == nil {
			hours := spec.DefaultDurationHours
			if input.Action == "mute" {
				var setting sql.NullString
				err := tx.QueryRowContext(ctx, spec.SQL["defaultMute"]).Scan(&setting)
				if err != nil && !errors.Is(err, sql.ErrNoRows) {
					return item, err
				}
				if value, ok := moderationHours(setting.String); ok {
					hours = max(value, int64(1))
				}
			}
			input.Hours = &hours
		}
		var caseID int64
		err = tx.QueryRowContext(ctx, spec.SQL["case"], key).Scan(&caseID)
		if errors.Is(err, sql.ErrNoRows) {
			if err := execModerationRow(ctx, tx, spec.SQL["create"], key); err != nil {
				return item, err
			}
			err = tx.QueryRowContext(ctx, spec.SQL["case"], key).Scan(&caseID)
		}
		if err != nil || caseID <= 0 {
			return item, errSessionStore
		}
		if input.Action == "ban" || input.Action == "unban" && banState {
			next, nextActive := "active", 1
			if input.Action == "ban" {
				next, nextActive = "suspended", 0
			}
			if err := execModerationRow(ctx, tx, spec.SQL["updateUser"], key, sql.Named("status", next), sql.Named("active", nextActive)); err != nil {
				return item, err
			}
		}
		if input.Action == "ban" {
			if _, err := tx.ExecContext(ctx, spec.SQL["revokeSessions"], key); err != nil {
				return item, err
			}
		}
		var duration sql.NullInt64
		if input.Hours != nil {
			duration = sql.NullInt64{Int64: *input.Hours, Valid: true}
		}
		hours, reason := sql.Named("hours", duration), sql.Named("reason", nullablePostString(input.Reason))
		if input.Action != "note" {
			kind := "mute"
			if input.Action == "ban" || input.Action == "unban" {
				kind = "ban"
			}
			kindArg := sql.Named("kind", kind)
			if _, err := tx.ExecContext(ctx, spec.SQL["revokeRestriction"], key, actor, kindArg); err != nil {
				return item, err
			}
			if adding {
				if err := execModerationRow(ctx, tx, spec.SQL["addRestriction"], key, actor, kindArg, reason, hours); err != nil {
					return item, err
				}
			}
		}
		if err := execModerationRow(ctx, tx, spec.SQL["audit"], key, actor, sql.Named("case_id", caseID), sql.Named("action", input.Action), reason, sql.Named("note", nullablePostString(input.Note)), hours); err != nil {
			return item, err
		}
		users, _, err := readModerationUsers(ctx, tx, sql.NullInt64{Int64: input.ID, Valid: true}, moderationUserFilters{Sort: "newest"}, SessionPage{Start: 1, End: 1}, storage)
		if err != nil || len(users) != 1 {
			return item, errSessionStore
		}
		return users[0], nil
	})
}

func handleModerationUserActions(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repo SessionRepository, config RefreshConfig) bool {
	const base = "/api/v2/moderation/users/"
	path := r.URL.EscapedPath()
	if r.Method != http.MethodPost || !strings.HasPrefix(path, base) {
		return false
	}
	raw, single := strings.CutSuffix(strings.TrimPrefix(path, base), "/actions")
	if !single || raw == "" || strings.Contains(raw, "/") {
		return false
	}
	viewer, ok := interactionActor(w, r, codec, repo)
	if !ok {
		return true
	}
	serverError := func() { respond(w, 500, 50001, "服务器内部错误", nil) }
	store, ok := repo.(moderationUserActionStore)
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
	raw, _ = url.PathUnescape(raw)
	id := moderationTargetID(raw)
	if id == 0 {
		respond(w, 400, 40001, "user_id 参数错误", nil)
		return true
	}
	if id == viewer {
		respond(w, 403, 40301, "不能处罚自己", nil)
		return true
	}
	body, ok := readLoginBody(r)
	if !ok {
		respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
		return true
	}
	input, invalid := parseUserAction(body, id)
	if invalid != "" {
		respond(w, 400, 40001, invalid, nil)
		return true
	}
	result, err := store.ModerateUser(ctx, viewer, input, config.Storage)
	switch {
	case errors.Is(err, errModerationUserMissing):
		respond(w, 404, 40401, "用户不存在", nil)
	case errors.Is(err, errModerationUserState):
		respond(w, 409, 40901, "账号状态不允许此处置", nil)
	case err != nil:
		serverError()
	default:
		respond(w, 200, 200, "user moderation action applied", result)
	}
	return true
}
