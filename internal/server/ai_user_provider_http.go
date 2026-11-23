package server

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
	"strings"
	"time"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

func testUserProviderConnection(ctx context.Context, settings userProviderSettings, owner int64, record *userProviderRecord) error {
	key, err := settings.open(owner, record)
	if err != nil {
		return err
	}
	bounded, cancel := context.WithTimeout(ctx, time.Duration(userProviderContract.TestTimeoutMS)*time.Millisecond)
	defer cancel()
	request, err := http.NewRequestWithContext(bounded, http.MethodGet, record.BaseURL+"/models", nil)
	if err != nil {
		return errUserProviderUnavailable
	}
	request.Header.Set("Authorization", "Bearer "+key)
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Accept-Encoding", "identity")
	client := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	response, err := client.Do(request)
	if err != nil {
		return errUserProviderUnavailable
	}
	defer response.Body.Close()
	encoding := response.Header.Get("Content-Encoding")
	if response.StatusCode < 200 || response.StatusCode >= 300 || (encoding != "" && !strings.EqualFold(encoding, "identity")) ||
		response.ContentLength > userProviderContract.TestMaxResponseBytes {
		return errUserProviderUnavailable
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, userProviderContract.TestMaxResponseBytes+1))
	if err != nil || int64(len(body)) > userProviderContract.TestMaxResponseBytes || bounded.Err() != nil {
		return errUserProviderUnavailable
	}
	var catalog struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	if json.Unmarshal(body, &catalog) != nil {
		return errUserProviderUnavailable
	}
	for _, model := range catalog.Data {
		if model.ID == record.Model {
			return nil
		}
	}
	return errUserProviderUnavailable
}

func userProviderHTTPError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, errUserProviderInvalid):
		respond(w, 400, 40001, "个人 AI 连接参数错误", nil)
	case errors.Is(err, errUserProviderMissing):
		respond(w, 404, 40401, "个人 AI 连接不存在", nil)
	case errors.Is(err, errUserProviderReconnect):
		respond(w, 409, 40901, "请重新填写密钥以连接个人 AI 服务", nil)
	default:
		respond(w, 503, 50301, "个人 AI 服务暂不可用", nil)
	}
}

func userProviderRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, settings userProviderSettings) bool {
	const path = "/api/v2/users/me/ai-provider"
	base := r.URL.EscapedPath() == path
	test := r.URL.EscapedPath() == path+"/test" && r.Method == http.MethodPost
	if !test && !(base && (r.Method == http.MethodGet || r.Method == http.MethodPut || r.Method == http.MethodDelete)) {
		return false
	}
	w.Header().Set("Cache-Control", "private, no-store")
	actor, ok := interactionActor(w, r, codec, repository)
	if !ok {
		return true
	}
	if settings.key == nil && r.Method != http.MethodDelete {
		if r.Method == http.MethodGet {
			respond(w, 200, 200, "success", settings.response(actor, nil))
		} else {
			userProviderHTTPError(w, errUserProviderUnavailable)
		}
		return true
	}
	store, ok := repository.(userProviderStore)
	if !ok {
		userProviderHTTPError(w, errUserProviderUnavailable)
		return true
	}
	ctx := r.Context()
	if test {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, time.Duration(userProviderContract.TestTimeoutMS)*time.Millisecond)
		defer cancel()
	}
	var result any
	var err error
	switch r.Method {
	case http.MethodGet:
		var record *userProviderRecord
		record, err = store.readUserProvider(ctx, actor)
		if err == nil {
			result = settings.response(actor, record)
		}
	case http.MethodPut:
		mediaType, _, mediaErr := mime.ParseMediaType(r.Header.Get("Content-Type"))
		body, readErr := io.ReadAll(io.LimitReader(r.Body, 4097))
		if mediaErr != nil || mediaType != "application/json" || readErr != nil || len(body) > 4096 {
			userProviderHTTPError(w, errUserProviderInvalid)
			return true
		}
		var input userProviderInput
		input, err = parseUserProviderInput(body)
		if err != nil {
			userProviderHTTPError(w, err)
			return true
		}
		var record userProviderRecord
		record, err = store.saveUserProvider(ctx, actor, settings, input)
		if err == nil {
			result = settings.response(actor, &record)
		}
	case http.MethodDelete:
		err = store.deleteUserProvider(ctx, actor)
	case http.MethodPost:
		var record *userProviderRecord
		record, err = store.readUserProvider(ctx, actor)
		if err == nil && record == nil {
			err = errUserProviderMissing
		}
		if err == nil {
			err = testUserProviderConnection(ctx, settings, actor, record)
		}
		if err == nil {
			result = struct {
				Verified bool `json:"verified"`
			}{true}
		}
	}
	if err != nil {
		userProviderHTTPError(w, err)
	} else {
		respond(w, 200, 200, "success", result)
	}
	return true
}
