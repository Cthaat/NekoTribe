package server

import (
	"context"
	"errors"
	"net/http"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type userSettingsStore interface {
	GetUserSettings(context.Context, int64) (userSettings, error)
}

func getUserSettings(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository) {
	w.Header().Set("Cache-Control", "private, no-store")
	user, ok := interactionActor(w, r, codec, repository)
	if !ok {
		return
	}
	store, ok := repository.(userSettingsStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	settings, err := store.GetUserSettings(r.Context(), user)
	if errors.Is(err, errSettingsSchema) {
		respond(w, 503, 50301, "服务暂不可用，请稍后重试。", nil)
		return
	}
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	respond(w, 200, 200, "success", settings)
}
