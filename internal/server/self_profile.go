package server

import (
	"context"
	"net/http"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type selfProfileStore interface {
	SelfProfile(context.Context, int64) (SelfUser, bool, error)
}

func getSelfProfile(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig) {
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
	store, ok := repository.(selfProfileStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
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
