package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
	"github.com/golang-jwt/jwt/v5"
)

type logoutStore struct {
	*rotationStore
	refreshCalls, accessCalls int
}

func (s *logoutStore) RevokeRefresh(_ context.Context, c auth.Claims, hash string) (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.refreshCalls++
	if s.fail {
		return 0, errors.New("private database detail")
	}
	if c.UserID != 42 || c.SessionID != "fixture-session-42" || s.revoked || hash != s.hash {
		return 0, nil
	}
	s.revoked = true
	return 1, nil
}
func (s *logoutStore) RevokeAccess(_ context.Context, c auth.Claims) (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.accessCalls++
	if s.fail {
		return 0, errors.New("private database detail")
	}
	if c.UserID != 42 || c.SessionID != "fixture-session-42" || s.revoked || c.JTI != s.accessJTI {
		return 0, nil
	}
	s.revoked = true
	return 1, nil
}

func logoutFixture(t *testing.T) (map[string]string, *logoutStore, http.Handler) {
	t.Helper()
	codec, tokens, s, _ := refreshFixture(t, false)
	store := &logoutStore{rotationStore: s}
	cfg := RefreshConfig{AccessSeconds: 120, RefreshSeconds: 3600, clock: func() time.Time { return time.Unix(1700000000, 123000000) }}
	return tokens, store, NewHandlerWithConfig(codec, store, CorsPolicy{Origins: []string{"https://app.example"}}, cfg)
}

func logoutRequest(handler http.Handler, body, cookie, authorization, contentType string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(http.MethodDelete, "/api/v2/auth/tokens/current", strings.NewReader(body))
	if contentType != "" {
		r.Header.Set("Content-Type", contentType)
	}
	if cookie != "" {
		r.Header.Set("Cookie", cookie)
	}
	if authorization != "" {
		r.Header.Set("Authorization", authorization)
	}
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	return w
}

func TestLogoutCredentialPriority(t *testing.T) {
	for _, tc := range []struct {
		name, body, cookie, authorization, contentType string
		revoked                                        bool
		refreshCalls, accessCalls                      int
	}{
		{"no credential", "{}", "", "", "application/json", false, 0, 0},
		{"refresh cookie", "", "REFRESH", "", "", true, 1, 0},
		{"refresh body", "BODY", "", "", "application/json", true, 1, 0},
		{"refresh form", "FORM", "", "", "application/x-www-form-urlencoded", true, 1, 0},
		{"access cookie", "{}", "ACCESS", "", "application/json", true, 0, 1},
		{"bearer", "{}", "", "BEARER", "application/json", true, 0, 1},
		{"bare header is not bearer", "{}", "", "RAW", "application/json", false, 0, 0},
		{"extra header text is rejected", "{}", "", "BAD-BEARER", "application/json", false, 0, 0},
		{"invalid refresh suppresses access", "{}", "refresh_token=invalid; ACCESS", "BEARER", "application/json", false, 0, 0},
		{"invalid refresh cookie suppresses body", "BODY", "refresh_token=invalid; ACCESS", "BEARER", "application/json", false, 0, 0},
		{"valid refresh overrides access", "BODY", "REFRESH; access_token=invalid", "", "application/json", true, 1, 0},
		{"invalid access cookie suppresses bearer", "{}", "access_token=invalid", "BEARER", "application/json", false, 0, 0},
		{"blank refresh cookie skips body and falls back to access", "BODY", `refresh_token="   "; ACCESS`, "", "application/json", true, 0, 1},
		{"empty refresh cookie falls back to body", "BODY", "refresh_token=; access_token=invalid", "", "application/json", true, 1, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tokens, store, handler := logoutFixture(t)
			body := strings.ReplaceAll(tc.body, "BODY", fmt.Sprintf(`{"refresh_token":%q}`, tokens["refresh-hs256"]))
			body = strings.ReplaceAll(body, "FORM", url.Values{"refresh_token": {tokens["refresh-hs256"]}}.Encode())
			cookie := strings.ReplaceAll(strings.ReplaceAll(tc.cookie, "REFRESH", "refresh_token="+tokens["refresh-hs256"]), "ACCESS", "access_token="+tokens["access-hs256"])
			authorization := strings.ReplaceAll(strings.ReplaceAll(strings.ReplaceAll(tc.authorization, "BAD-BEARER", "Bearer "+tokens["access-hs256"]+" extra"), "BEARER", "bEaReR  "+tokens["access-hs256"]), "RAW", tokens["access-hs256"])
			w := logoutRequest(handler, body, cookie, authorization, tc.contentType)
			if w.Code != 200 || store.revoked != tc.revoked || store.refreshCalls != tc.refreshCalls || store.accessCalls != tc.accessCalls {
				t.Fatalf("status=%d revoked=%v refresh=%d access=%d", w.Code, store.revoked, store.refreshCalls, store.accessCalls)
			}
			var response struct {
				Code       int    `json:"code"`
				Message    string `json:"message"`
				Data, Meta interface{}
			}
			if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil || response.Code != 200 || response.Message != "logout success" || response.Data != nil || response.Meta != nil {
				t.Fatalf("invalid response %s", w.Body.String())
			}
			cookies := w.Result().Cookies()
			if len(cookies) != 2 {
				t.Fatalf("expected two cleared cookies: %v", cookies)
			}
			for _, c := range cookies {
				if (c.Name != "access_token" && c.Name != "refresh_token") || c.Value != "" || c.Path != "/" || c.MaxAge != -1 {
					t.Fatalf("bad deletion cookie: %v", c)
				}
			}
		})
	}
}

func TestLogoutStaleCredentialsAndStoreFailure(t *testing.T) {
	tokens, store, handler := logoutFixture(t)
	first := refreshRequest(handler, fmt.Sprintf(`{"refresh_token":%q}`, tokens["refresh-hs256"]), "")
	if first.Code != 200 {
		t.Fatal(first.Code)
	}
	for _, tc := range []struct{ body, authorization string }{
		{fmt.Sprintf(`{"refresh_token":%q}`, tokens["refresh-hs256"]), ""},
		{"{}", "Bearer " + tokens["access-hs256"]},
	} {
		w := logoutRequest(handler, tc.body, "", tc.authorization, "application/json")
		if w.Code != 200 || store.revoked {
			t.Fatalf("stale credentials revoked session: %s", w.Body.String())
		}
	}
	var rotated struct {
		Data struct {
			Refresh string `json:"refresh_token"`
		} `json:"data"`
	}
	if err := json.Unmarshal(first.Body.Bytes(), &rotated); err != nil {
		t.Fatal(err)
	}
	store.fail = true
	w := logoutRequest(handler, fmt.Sprintf(`{"refresh_token":%q}`, rotated.Data.Refresh), "", "", "application/json")
	if w.Code != 500 || store.revoked || len(w.Result().Cookies()) != 0 || strings.Contains(w.Body.String(), "private") {
		t.Fatalf("unsafe store failure %d %s", w.Code, w.Body.String())
	}
	store.fail = false
	w = logoutRequest(handler, fmt.Sprintf(`{"refresh_token":%q}`, rotated.Data.Refresh), "", "", "application/json")
	if w.Code != 200 || !store.revoked {
		t.Fatalf("valid rotated token did not revoke %d", w.Code)
	}
	if refreshRequest(handler, fmt.Sprintf(`{"refresh_token":%q}`, rotated.Data.Refresh), "").Code != 401 {
		t.Fatal("revoked refresh still accepted")
	}
}

func TestLogoutUsesCredentialDespiteExpiredDatabaseDeadline(t *testing.T) {
	tokens, store, handler := logoutFixture(t)
	store.expires = time.Unix(1699999999, 0)
	w := logoutRequest(handler, fmt.Sprintf(`{"refresh_token":%q}`, tokens["refresh-hs256"]), "", "", "application/json")
	if w.Code != 200 || !store.revoked {
		t.Fatal("valid JWT should revoke a matching expired session")
	}
}

func TestLogoutChoosesRefreshWhenValidAccessIsAnotherSession(t *testing.T) {
	codec, tokens, original, _ := refreshFixture(t, false)
	store := &logoutStore{rotationStore: original}
	handler := NewHandler(codec, store, CorsPolicy{})
	otherAccess, err := codec.Sign(auth.Claims{UserID: 99, SessionID: "other-session", JTI: "other-jti", Kind: auth.Access}, 900)
	if err != nil {
		t.Fatal(err)
	}
	body := fmt.Sprintf(`{"refresh_token":%q}`, tokens["refresh-hs256"])
	w := logoutRequest(handler, body, "access_token="+otherAccess, "", "application/json")
	if w.Code != 200 || !store.revoked || store.refreshCalls != 1 || store.accessCalls != 0 {
		t.Fatal("logout did not choose the refresh session")
	}
}

func TestLogoutAndRotationCompeteOnCurrentCredential(t *testing.T) {
	for i := 0; i < 20; i++ {
		tokens, store, handler := logoutFixture(t)
		body := fmt.Sprintf(`{"refresh_token":%q}`, tokens["refresh-hs256"])
		start := make(chan struct{})
		var wg sync.WaitGroup
		var refresh, logout *httptest.ResponseRecorder
		wg.Add(2)
		go func() { defer wg.Done(); <-start; refresh = refreshRequest(handler, body, "") }()
		go func() { defer wg.Done(); <-start; logout = logoutRequest(handler, body, "", "", "application/json") }()
		close(start)
		wg.Wait()
		if logout.Code != 200 {
			t.Fatalf("logout %d", logout.Code)
		}
		if refresh.Code == 200 && store.revoked {
			t.Fatal("old refresh revoked a rotated session")
		}
		if refresh.Code == 401 && !store.revoked {
			t.Fatal("failed rotation did not follow a matching logout")
		}
		if refresh.Code != 200 && refresh.Code != 401 {
			t.Fatalf("unexpected refresh status %d", refresh.Code)
		}
	}
}

func TestLogoutAndRefreshBothCommitOrders(t *testing.T) {
	for _, refreshFirst := range []bool{false, true} {
		t.Run(fmt.Sprintf("refresh_first_%v", refreshFirst), func(t *testing.T) {
			tokens, store, handler := logoutFixture(t)
			body := fmt.Sprintf(`{"refresh_token":%q}`, tokens["refresh-hs256"])
			if refreshFirst {
				if got := refreshRequest(handler, body, ""); got.Code != 200 {
					t.Fatalf("initial refresh: %d", got.Code)
				}
				if got := logoutRequest(handler, body, "", "", "application/json"); got.Code != 200 || store.revoked {
					t.Fatalf("stale logout: status %d revoked %v", got.Code, store.revoked)
				}
			} else {
				if got := logoutRequest(handler, body, "", "", "application/json"); got.Code != 200 || !store.revoked {
					t.Fatalf("initial logout: status %d revoked %v", got.Code, store.revoked)
				}
				if got := refreshRequest(handler, body, ""); got.Code != 401 {
					t.Fatalf("refresh after logout: %d", got.Code)
				}
			}
		})
	}
}

func TestLogoutAcceptsRefreshWithoutJTI(t *testing.T) {
	_, store, handler := logoutFixture(t)
	token, err := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{"userId": 42, "sessionId": "fixture-session-42", "type": "refresh", "exp": 1700001000}).SignedString([]byte("public-fixture-refresh-key-never-use-in-production-2026"))
	if err != nil {
		t.Fatal(err)
	}
	store.hash = refreshHash(token)
	w := logoutRequest(handler, fmt.Sprintf(`{"refresh_token":%q}`, token), "", "", "application/json")
	if w.Code != 200 || !store.revoked {
		t.Fatal("valid legacy refresh rejected")
	}
}

func TestLogoutRejectsExpiredAndWrongTypeCredentials(t *testing.T) {
	for _, tc := range []struct {
		name, kind, key string
		expiration      int64
	}{
		{"expired refresh", "refresh", "public-fixture-refresh-key-never-use-in-production-2026", 1699999999},
		{"wrong type signed with refresh key", "access", "public-fixture-refresh-key-never-use-in-production-2026", 1700001000},
		{"wrong signature", "refresh", "incorrect-key", 1700001000},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tokens, store, handler := logoutFixture(t)
			token, err := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{"userId": 42, "sessionId": "fixture-session-42", "type": tc.kind, "exp": tc.expiration}).SignedString([]byte(tc.key))
			if err != nil {
				t.Fatal(err)
			}
			store.hash = refreshHash(token)
			w := logoutRequest(handler, fmt.Sprintf(`{"refresh_token":%q}`, token), "access_token="+tokens["access-hs256"], "", "application/json")
			if w.Code != 200 || store.revoked || store.refreshCalls != 0 || store.accessCalls != 0 || len(w.Result().Cookies()) != 2 {
				t.Fatal("invalid credential affected session")
			}
		})
	}
}

func TestLogoutOverLoopbackHTTP(t *testing.T) {
	tokens, store, handler := logoutFixture(t)
	srv := httptest.NewServer(handler)
	defer srv.Close()
	req, err := http.NewRequest(http.MethodDelete, srv.URL+"/api/v2/auth/tokens/current", strings.NewReader(fmt.Sprintf(`{"refresh_token":%q}`, tokens["refresh-hs256"])))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Origin", "https://app.example")
	response, err := srv.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != 200 || !store.revoked || response.Header.Get("Access-Control-Allow-Origin") != "https://app.example" || len(response.Cookies()) != 2 {
		t.Fatal("logout over HTTP failed")
	}
}

func TestLogoutCORSPreflight(t *testing.T) {
	_, store, handler := logoutFixture(t)
	r := httptest.NewRequest(http.MethodOptions, "/api/v2/auth/tokens/current", nil)
	r.Header.Set("Origin", "https://app.example")
	r.Header.Set("Access-Control-Request-Method", "DELETE")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	if w.Code != 204 || w.Header().Get("Access-Control-Allow-Origin") != "https://app.example" || store.accessCalls != 0 || store.refreshCalls != 0 {
		t.Fatal("invalid preflight")
	}
	r.Header.Set("Origin", "https://disallowed.example")
	w = httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	if w.Code != 403 || store.accessCalls != 0 || store.refreshCalls != 0 {
		t.Fatal("disallowed preflight touched storage or was accepted")
	}
}
