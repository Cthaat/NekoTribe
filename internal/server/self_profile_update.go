package server

import (
	"context"
	"database/sql"
	"net/http"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

var profileUpdateKeys = [...]string{"display_name", "bio", "location", "website", "phone", "birth_date"}

type profileUpdateStore interface {
	selfProfileStore
	UpdateSelfProfile(context.Context, int64, map[string]string) error
}

func (s OracleSessions) UpdateSelfProfile(ctx context.Context, user int64, fields map[string]string) error {
	clauses := make([]string, 0, len(fields))
	args := []interface{}{sql.Named("user_id", user)}
	for _, key := range profileUpdateKeys {
		value, present := fields[key]
		if !present {
			continue
		}
		if key == "birth_date" {
			clauses = append(clauses, "birth_date = CASE WHEN :birth_date IS NULL THEN NULL ELSE TO_DATE(:birth_date, 'YYYY-MM-DD') END")
		} else {
			clauses = append(clauses, key+" = :"+key)
		}
		args = append(args, sql.Named(key, nullableRegistration(value)))
	}
	if len(clauses) == 0 {
		return nil
	}
	_, err := s.execute(ctx, "UPDATE n_users SET "+strings.Join(clauses, ", ")+" WHERE user_id = :user_id", args...)
	return err
}

func updateSelfProfile(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig) {
	w.Header().Set("Cache-Control", "private, no-store")
	token := accessToken(r)
	if token == "" {
		respond(w, 401, 40101, "请先登录", nil)
		return
	}
	claims, err := codec.Verify(token, auth.Access)
	if err != nil {
		respond(w, 401, 40101, "Token无效或已过期", nil)
		return
	}
	if count, err := repository.Touch(r.Context(), claims); err != nil || count != 1 {
		respond(w, 401, 40101, "Token无效或已过期", nil)
		return
	}
	body, ok := readLoginBody(r)
	if !ok {
		respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
		return
	}
	store, ok := repository.(profileUpdateStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	fields := make(map[string]string)
	for _, key := range profileUpdateKeys {
		if v, present := body[key]; present {
			fields[key] = registrationString(v)
		}
	}
	if len(fields) > 0 {
		if err = store.UpdateSelfProfile(r.Context(), claims.UserID, fields); err != nil {
			respond(w, 500, 50001, "服务器内部错误", nil)
			return
		}
	}
	profile, found, err := store.SelfProfile(r.Context(), claims.UserID)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if !found {
		respond(w, 404, 40401, "用户不存在", nil)
		return
	}
	profile.AvatarURL, err = normalizeAvatarURL(config.Storage, profile.AvatarURL)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	respond(w, 200, 200, "success", profile)
}
