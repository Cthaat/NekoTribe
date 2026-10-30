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
	user                      int64
	err                       error
	presenceErr               error
	patchCalls, presenceCalls int
	patch                     settingsPatch
}

func (s *settingsRouteStore) GetUserSettings(_ context.Context, user int64) (userSettings, error) {
	s.user = user
	return userSettings{UserID: user, ProfileVisibility: "public", AISentimentTopK: 3}, s.err
}

func (s *settingsRouteStore) PatchUserSettings(_ context.Context, user int64, patch settingsPatch) (userSettings, error) {
	s.user = user
	s.patch = patch
	s.patchCalls++
	return userSettings{UserID: user}, s.err
}
func (s *settingsRouteStore) UserPresence(_ context.Context, user int64) (userPresence, error) {
	s.presenceCalls++
	return userPresence{UserID: user, OnlineStatus: "hidden"}, s.presenceErr
}

type fakePresencePublisher struct {
	calls    int
	presence userPresence
	fail     bool
}

func (p *fakePresencePublisher) PublishPresence(_ context.Context, presence userPresence) error {
	p.calls++
	p.presence = presence
	if p.fail {
		return errors.New("secret")
	}
	return nil
}

func TestPatchUserSettingsRoute(t *testing.T) {
	codec, tokens := fixture(t)
	for _, tc := range []struct {
		name, body                       string
		token                            bool
		storeErr, presenceErr            error
		publisherFail                    bool
		status, writes, reads, publishes int
	}{
		{"update", `{"show_online_status":false}`, true, nil, nil, false, 200, 1, 1, 1},
		{"other setting", `{"login_alerts":true}`, true, nil, nil, false, 200, 1, 0, 0},
		{"restricted", `{"two_factor_enabled":false}`, true, nil, nil, false, 400, 0, 0, 0},
		{"anonymous", `{}`, false, nil, nil, false, 401, 0, 0, 0},
		{"schema", `{}`, true, errSettingsSchema, nil, false, 503, 1, 0, 0},
		{"presence lookup", `{"show_online_status":true}`, true, nil, errors.New("secret"), false, 500, 1, 1, 0},
		{"redis degraded", `{"show_online_status":true}`, true, nil, nil, true, 200, 1, 1, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			store := &settingsRouteStore{memorySessions: store(), err: tc.storeErr, presenceErr: tc.presenceErr}
			publisher := &fakePresencePublisher{fail: tc.publisherFail}
			req := httptest.NewRequest("PATCH", "/api/v2/users/me/settings", strings.NewReader(tc.body))
			req.Header.Set("Content-Type", "application/json")
			if tc.token {
				req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			}
			w := httptest.NewRecorder()
			NewHandlerWithConfig(codec, store, CorsPolicy{}, RefreshConfig{PresencePublisher: publisher}).ServeHTTP(w, req)
			if w.Code != tc.status || store.patchCalls != tc.writes || store.presenceCalls != tc.reads || publisher.calls != tc.publishes || strings.Contains(w.Body.String(), "secret") {
				t.Fatal(w.Code, store, publisher, w.Body.String())
			}
			if tc.writes > 0 && store.user != 42 {
				t.Fatal(store.user)
			}
		})
	}
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
