package server

import (
	"context"
	"errors"
	"net/http/httptest"
	"strings"
	"testing"
)

type settingsRouteStore struct {
	*memorySessions
	user int64
	err  error
}

func (s *settingsRouteStore) GetUserSettings(_ context.Context, user int64) (userSettings, error) {
	s.user = user
	return userSettings{UserID: user, ProfileVisibility: "public", AISentimentTopK: 3}, s.err
}

func TestGetUserSettingsRoute(t *testing.T) {
	codec, tokens := fixture(t)
	for _, tc := range []struct {
		name   string
		token  string
		err    error
		status int
	}{
		{"ok", tokens["access-hs256"], nil, 200},
		{"missing", "", nil, 401},
		{"schema", tokens["access-hs256"], errSettingsSchema, 503},
		{"storage", tokens["access-hs256"], errors.New("secret"), 500},
	} {
		t.Run(tc.name, func(t *testing.T) {
			store := &settingsRouteStore{memorySessions: store(), err: tc.err}
			req := httptest.NewRequest("GET", "/api/v2/users/me/settings", nil)
			if tc.token != "" {
				req.Header.Set("Authorization", "Bearer "+tc.token)
			}
			w := httptest.NewRecorder()
			NewHandler(codec, store, CorsPolicy{}).ServeHTTP(w, req)
			if w.Code != tc.status || w.Header().Get("Cache-Control") != "private, no-store" || strings.Contains(w.Body.String(), "secret") {
				t.Fatal(w.Code, w.Body.String())
			}
			if tc.status == 200 && (store.user != 42 || !strings.Contains(w.Body.String(), `"user_id":42`)) {
				t.Fatal(store.user, w.Body.String())
			}
		})
	}
}
