package server

import (
	"context"
	"errors"
	"log"
	"net/http"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type userSettingsStore interface {
	GetUserSettings(context.Context, int64) (userSettings, error)
}

type userSettingsPatchStore interface {
	PatchUserSettings(context.Context, int64, settingsPatch) (userSettings, error)
	UserPresence(context.Context, int64) (userPresence, error)
}

func patchUserSettings(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig) {
	w.Header().Set("Cache-Control", "private, no-store")
	user, ok := interactionActor(w, r, codec, repository)
	if !ok {
		return
	}
	body, ok := readLoginBody(r)
	if !ok {
		respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
		return
	}
	patch, err := parseSettingsPatch(body)
	if err != nil {
		respond(w, 400, 40001, err.Error(), nil)
		return
	}
	store, ok := repository.(userSettingsPatchStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	settings, err := store.PatchUserSettings(r.Context(), user, patch)
	if settingsMissingResponse(w, err) {
		return
	}
	if errors.Is(err, errSettingsSchema) {
		respond(w, 503, 50301, "服务暂不可用，请稍后重试。", nil)
		return
	}
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if patch.PublishPresence {
		presence, presenceErr := store.UserPresence(r.Context(), user)
		if presenceErr != nil {
			respond(w, 500, 50001, "服务器内部错误", nil)
			return
		}
		if config.PresencePublisher == nil || config.PresencePublisher.PublishPresence(r.Context(), presence) != nil {
			log.Print("presence delivery unavailable")
		}
	}
	respond(w, 200, 200, "success", settings)
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
	if settingsMissingResponse(w, err) {
		return
	}
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

func settingsMissingResponse(w http.ResponseWriter, err error) bool {
	if errors.Is(err, errSettingsUserMissing) {
		respond(w, 404, 40401, "用户不存在", nil)
		return true
	}
	if errors.Is(err, errSettingsMissing) {
		respond(w, 404, 40401, "用户设置不存在", nil)
		return true
	}
	return false
}
