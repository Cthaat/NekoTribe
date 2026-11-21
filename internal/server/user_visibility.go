package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type visibilityKind string

const (
	visibilityBlocks visibilityKind = "blocks"
	visibilityMutes  visibilityKind = "mutes"
)

var visibilitySQL = mustVisibilitySQL()

func mustVisibilitySQL() map[string]string {
	var queries map[string]string
	if err := json.Unmarshal(contracts.UserVisibilitySQL, &queries); err != nil {
		panic("invalid user visibility SQL contract")
	}
	return queries
}

type visibilityItem struct {
	PublicUser
	ExpiresAt **string `json:"expires_at,omitempty"`
}

type userVisibilityStore interface {
	ListUserVisibility(context.Context, int64, visibilityKind, SessionPage) ([]visibilityItem, int64, error)
	WriteUserVisibility(context.Context, int64, int64, visibilityKind, bool, *string) (bool, error)
}

func (s OracleSessions) ListUserVisibility(ctx context.Context, viewer int64, kind visibilityKind, page SessionPage) ([]visibilityItem, int64, error) {
	return s.listRelationshipRows(ctx, viewer, nil, string(kind), page)
}

func (s OracleSessions) listRelationshipRows(ctx context.Context, viewer int64, target *int64, kind string, page SessionPage) ([]visibilityItem, int64, error) {
	binds := []any{sql.Named("viewer_id", viewer), sql.Named("start_row", page.Start), sql.Named("end_row", page.End)}
	if target != nil {
		binds = append(binds, sql.Named("target_id", *target))
	}
	rows, err := s.DB.QueryContext(ctx, visibilitySQL[kind], binds...)
	if err != nil {
		return nil, 0, errSessionStore
	}
	defer rows.Close()
	list := []visibilityItem{}
	var total int64
	for rows.Next() {
		var expiry sql.NullString
		profile, err := scanPublicUser(rows, &expiry, &total)
		if err != nil {
			return nil, 0, errSessionStore
		}
		if profile.UserID == 0 {
			continue
		}
		item := visibilityItem{PublicUser: profile}
		if kind == string(visibilityMutes) {
			var value *string
			if expiry.Valid {
				value = &expiry.String
			}
			item.ExpiresAt = &value
		}
		list = append(list, item)
	}
	if rows.Err() != nil {
		return nil, 0, errSessionStore
	}
	return list, total, nil
}

func (s OracleSessions) WriteUserVisibility(ctx context.Context, actor, target int64, kind visibilityKind, remove bool, expiry *string) (bool, error) {
	binds := []any{sql.Named("actor_id", actor), sql.Named("target_id", target)}
	if remove {
		statement := visibilitySQL["unblock"]
		if kind == visibilityMutes {
			statement = visibilitySQL["unmute"]
		}
		_, err := s.execute(ctx, statement, binds...)
		return err == nil, err
	}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return false, errSessionStore
	}
	defer tx.Rollback()
	var id int64
	if found, err := lockVisibilityPair(ctx, tx, actor, target); !found || err != nil {
		return false, err
	}
	if err = tx.QueryRowContext(ctx, visibilitySQL["activeTarget"], sql.Named("target_id", target)).Scan(&id); err != nil {
		return false, visibilityTargetError(err)
	}
	if kind == visibilityBlocks {
		if _, err = tx.ExecContext(ctx, visibilitySQL["block"], binds...); err == nil {
			_, err = tx.ExecContext(ctx, visibilitySQL["cancelFollows"], binds...)
		}
	} else {
		var expires any
		if expiry != nil {
			expires = strings.TrimSuffix(*expiry, "Z") + "+00:00"
		}
		_, err = tx.ExecContext(ctx, visibilitySQL["mute"], append(binds, sql.Named("expires_at", expires))...)
	}
	if err != nil || tx.Commit() != nil {
		return false, errSessionStore
	}
	return true, nil
}

func lockVisibilityPair(ctx context.Context, tx *sql.Tx, actor, target int64) (bool, error) {
	ids := []int64{min(actor, target)}
	if actor != target {
		ids = append(ids, max(actor, target))
	}
	var id int64
	for _, user := range ids {
		if err := tx.QueryRowContext(ctx, visibilitySQL["lockUser"], sql.Named("user_id", user)).Scan(&id); err != nil {
			return false, visibilityTargetError(err)
		}
	}
	return true, nil
}

func visibilityTargetError(err error) error {
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	return errSessionStore
}

var visibilityExpiryPattern = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]{1,9})?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$`)

func parseMuteExpiry(value any) (*string, bool) {
	if value == nil || value == "" {
		return nil, true
	}
	raw, ok := value.(string)
	if !ok || !visibilityExpiryPattern.MatchString(raw) || strings.HasPrefix(raw, "0000") {
		return nil, false
	}
	instant, err := time.Parse(time.RFC3339Nano, raw)
	if err != nil || instant.UTC().Year() < 1 || instant.UTC().Year() > 9999 {
		return nil, false
	}
	utc := instant.UTC().Format("2006-01-02T15:04:05.000Z")
	return &utc, true
}

func handleUserVisibility(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig) bool {
	path, ok := strings.CutPrefix(r.URL.EscapedPath(), "/api/v2/users/me/")
	if !ok {
		return false
	}
	group, raw, hasTarget := strings.Cut(path, "/")
	kind := visibilityKind(group)
	if kind != visibilityBlocks && kind != visibilityMutes {
		return false
	}
	if !hasTarget && r.Method == http.MethodGet {
		listUserVisibility(w, r, codec, repository, config, kind)
		return true
	}
	if hasTarget && raw != "" && !strings.Contains(raw, "/") && (r.Method == http.MethodPost || r.Method == http.MethodDelete) {
		writeUserVisibility(w, r, codec, repository, kind, raw)
		return true
	}
	return false
}

func listUserVisibility(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig, kind visibilityKind) {
	viewer, ok := interactionActor(w, r, codec, repository)
	if !ok {
		return
	}
	store, ok := repository.(userVisibilityStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	page := sessionPagination(parseSessionQuery(r.URL.RawQuery))
	list, total, err := store.ListUserVisibility(r.Context(), viewer, kind, page)
	if err == nil {
		for i := range list {
			list[i].AvatarURL, err = normalizeAvatarURL(config.Storage, list[i].AvatarURL)
			if err != nil {
				break
			}
		}
	}
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	writeRelationshipPage(w, list, total, page)
}

func writeRelationshipPage[T any](w http.ResponseWriter, list []T, total int64, page SessionPage) {
	if list == nil {
		list = []T{}
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(map[string]any{"code": 200, "message": "success", "data": list, "meta": map[string]any{
		"page": page.Page, "page_size": page.PageSize, "total": total, "has_next": page.End < float64(total),
	}})
}

func writeUserVisibility(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, kind visibilityKind, raw string) {
	actor, ok := interactionActor(w, r, codec, repository)
	if !ok {
		return
	}
	raw, err := url.PathUnescape(raw)
	target, parseErr := strconv.ParseInt(raw, 10, 64)
	if err != nil || parseErr != nil || !publicID.MatchString(raw) || target > 9007199254740991 {
		respond(w, 400, 40001, "target_id 参数错误", nil)
		return
	}
	remove := r.Method == http.MethodDelete
	if actor == target && !remove {
		message := "不能屏蔽自己"
		if kind == visibilityMutes {
			message = "不能静音自己"
		}
		respond(w, 422, 42201, message, nil)
		return
	}
	var expiry *string
	if !remove && kind == visibilityMutes && r.ContentLength != 0 {
		body, valid := readLoginBody(r)
		if !valid {
			respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
			return
		}
		expiry, valid = parseMuteExpiry(body["expires_at"])
		if !valid {
			respond(w, 400, 40001, "expires_at 参数错误", nil)
			return
		}
	}
	store, ok := repository.(userVisibilityStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	found, err := store.WriteUserVisibility(r.Context(), actor, target, kind, remove, expiry)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if !found {
		respond(w, 404, 40401, "用户不存在", nil)
		return
	}
	result := map[string]any{"target_user_id": target, "relationship": "none"}
	if !remove {
		result["relationship"] = "blocking"
		if kind == visibilityMutes {
			result["relationship"] = "muted"
			result["expires_at"] = expiry
		}
	}
	respond(w, 200, 200, "success", result)
}
