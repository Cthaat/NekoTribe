package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
	"github.com/golang-jwt/jwt/v5"
)

func TestRefreshRouteRequiresCredentials(t *testing.T) {
	codec, _ := fixture(t)
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodPatch, "/api/v2/auth/tokens/current", strings.NewReader(`{}`))
	NewHandler(codec, store(), CorsPolicy{}).ServeHTTP(w, r)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("got %d, want 401: %s", w.Code, w.Body.String())
	}
}

type rotationStore struct {
	mu              sync.Mutex
	hash, accessJTI string
	expires         time.Time
	revoked, fail   bool
	calls           int
}

func (s *rotationStore) Touch(_ context.Context, claims auth.Claims) (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if claims.UserID == 42 && claims.SessionID == "fixture-session-42" && claims.JTI == s.accessJTI && !s.revoked {
		return 1, nil
	}
	return 0, nil
}
func (s *rotationStore) Revoke(context.Context, int64, string) (int64, error)       { return 0, nil }
func (s *rotationStore) RevokeOthers(context.Context, int64, string) (int64, error) { return 0, nil }
func (s *rotationStore) Rotate(_ context.Context, r Rotation) (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls++
	if s.fail {
		return 0, errors.New("private database detail")
	}
	if s.revoked || !s.expires.After(time.Unix(1700000000, 0)) || r.UserID != 42 || r.SessionID != "fixture-session-42" || r.OldHash != s.hash {
		return 0, nil
	}
	s.hash, s.accessJTI, s.expires = r.NewHash, r.AccessJTI, r.RefreshExpiresAt
	return 1, nil
}
func refreshFixture(t *testing.T, secure bool) (*auth.TokenManager, map[string]string, *rotationStore, http.Handler) {
	t.Helper()
	c, tokens := fixture(t)
	s := &rotationStore{hash: refreshHash(tokens["refresh-hs256"]), accessJTI: "fixture-access-jti-42", expires: time.Unix(1700002000, 0)}
	cfg := RefreshConfig{AccessSeconds: 120, RefreshSeconds: 3600, CookieSecure: secure, clock: func() time.Time { return time.Unix(1700000000, 123000000) }}
	return c, tokens, s, NewHandlerWithConfig(c, s, CorsPolicy{Origins: []string{"https://app.example"}}, cfg)
}
func refreshRequest(handler http.Handler, body, cookie string) *httptest.ResponseRecorder {
	r := httptest.NewRequest("PATCH", "/api/v2/auth/tokens/current", strings.NewReader(body))
	r.Header.Set("Content-Type", "application/json")
	if cookie != "" {
		r.Header.Set("Cookie", cookie)
	}
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	return w
}
func TestRefreshRotatesBothTokensAndRejectsReplay(t *testing.T) {
	codec, tokens, s, handler := refreshFixture(t, true)
	w := refreshRequest(handler, fmt.Sprintf(`{"refresh_token":%q}`, tokens["refresh-hs256"]), "")
	if w.Code != 200 {
		t.Fatalf("%d %s", w.Code, w.Body.String())
	}
	var body struct {
		Code    int
		Message string
		Meta    interface{}
		Data    struct {
			SessionID      string `json:"session_id"`
			Access         string `json:"access_token"`
			Refresh        string `json:"refresh_token"`
			AccessExpires  string `json:"access_token_expires_at"`
			RefreshExpires string `json:"refresh_token_expires_at"`
		}
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.Code != 200 || body.Message != "success" || body.Meta != nil || body.Data.SessionID != "fixture-session-42" || body.Data.AccessExpires != "2023-11-14T22:15:20.123Z" || body.Data.RefreshExpires != "2023-11-14T23:13:20.123Z" {
		t.Fatalf("unexpected response: %+v", body)
	}
	a, err := codec.Verify(body.Data.Access, auth.Access)
	if err != nil || a.JTI != s.accessJTI || a.UserID != 42 {
		t.Fatal("invalid new access", err)
	}
	r, err := codec.Verify(body.Data.Refresh, auth.Refresh)
	if err != nil || r.UserID != 42 || r.SessionID != a.SessionID || r.JTI == a.JTI || s.hash != refreshHash(body.Data.Refresh) {
		t.Fatal("invalid new refresh", err)
	}
	old, err := codec.Verify(tokens["access-hs256"], auth.Access)
	if err != nil {
		t.Fatal(err)
	}
	affected, _ := s.Touch(context.Background(), old)
	if affected != 0 {
		t.Fatal("old access still authorized")
	}
	cookies := w.Result().Cookies()
	if len(cookies) != 2 {
		t.Fatal("missing cookies")
	}
	for _, c := range cookies {
		if !c.HttpOnly || !c.Secure || c.SameSite != http.SameSiteLaxMode || c.Path != "/" || (c.Name == "access_token" && (c.Value != body.Data.Access || c.MaxAge != 120)) || (c.Name == "refresh_token" && (c.Value != body.Data.Refresh || c.MaxAge != 3600)) {
			t.Fatalf("unexpected cookie %s", c.Name)
		}
	}
	if replay := refreshRequest(handler, fmt.Sprintf(`{"refresh_token":%q}`, tokens["refresh-hs256"]), ""); replay.Code != 401 || len(replay.Result().Cookies()) != 0 {
		t.Fatal("old token replay accepted")
	}
	if next := refreshRequest(handler, fmt.Sprintf(`{"refresh_token":%q}`, body.Data.Refresh), ""); next.Code != 200 {
		t.Fatalf("new refresh failed: %d %s", next.Code, next.Body.String())
	}
}

func TestRefreshCredentialPrecedenceAndFailures(t *testing.T) {
	for _, tc := range []struct {
		name, cookie, body     string
		status, calls          int
		revoked, expired, fail bool
	}{
		{"missing", "", `{}`, 401, 0, false, false, false},
		{"malformed body", "", `{`, 401, 0, false, false, false},
		{"non-string body", "", `"text"`, 401, 0, false, false, false},
		{"wrong type", "", `{"refresh_token":12}`, 401, 0, false, false, false},
		{"invalid cookie wins", "refresh_token=invalid", "VALID", 401, 0, false, false, false},
		{"whitespace cookie wins", `refresh_token="   "`, "VALID", 401, 0, false, false, false},
		{"empty cookie falls back", "refresh_token=", "VALID", 200, 1, false, false, false},
		{"valid cookie wins", "VALID", `{"refresh_token":"invalid"}`, 200, 1, false, false, false},
		{"revoked", "", "VALID", 401, 1, true, false, false},
		{"expired session", "", "VALID", 401, 1, false, true, false},
		{"database failure", "", "VALID", 500, 1, false, false, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, tokens, store, handler := refreshFixture(t, false)
			store.revoked, store.fail = tc.revoked, tc.fail
			if tc.expired {
				store.expires = time.Unix(1700000000, 0)
			}
			body, cookie := tc.body, tc.cookie
			if body == "VALID" {
				body = fmt.Sprintf(`{"refresh_token":%q}`, tokens["refresh-hs256"])
			}
			if cookie == "VALID" {
				cookie = "refresh_token=" + tokens["refresh-hs256"]
			}
			w := refreshRequest(handler, body, cookie)
			if w.Code != tc.status || store.calls != tc.calls {
				t.Fatalf("status=%d calls=%d body=%s", w.Code, store.calls, w.Body.String())
			}
			if strings.Contains(w.Body.String(), "private") {
				t.Fatal("database error leaked")
			}
			if tc.status != 200 && len(w.Result().Cookies()) != 0 {
				t.Fatal("failure wrote cookies")
			}
		})
	}
}

func TestRefreshRejectsTrailingJSON(t *testing.T) {
	_, tokens, store, handler := refreshFixture(t, false)
	body := fmt.Sprintf(`{"refresh_token":%q} garbage`, tokens["refresh-hs256"])
	w := refreshRequest(handler, body, "")
	if w.Code != 401 || store.calls != 0 {
		t.Fatal("malformed JSON accepted")
	}
}

func TestConcurrentRefreshOnlyOneSucceeds(t *testing.T) {
	_, tokens, _, handler := refreshFixture(t, false)
	const attempts = 16
	results := make(chan int, attempts)
	var wg sync.WaitGroup
	for i := 0; i < attempts; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			w := refreshRequest(handler, fmt.Sprintf(`{"refresh_token":%q}`, tokens["refresh-hs256"]), "")
			results <- w.Code
		}()
	}
	wg.Wait()
	close(results)
	success, unauthorized := 0, 0
	for status := range results {
		if status == 200 {
			success++
		} else if status == 401 {
			unauthorized++
		} else {
			t.Fatal(status)
		}
	}
	if success != 1 || unauthorized != attempts-1 {
		t.Fatalf("success %d unauthorized %d", success, unauthorized)
	}
}

func TestRefreshAcceptsLegacyJWTWithoutJTI(t *testing.T) {
	_, _, s, handler := refreshFixture(t, false)
	key := []byte("public-fixture-refresh-key-never-use-in-production-2026")
	token, err := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{"userId": 42, "userName": "legacy", "sessionId": "fixture-session-42", "type": "refresh", "exp": 1700001000}).SignedString(key)
	if err != nil {
		t.Fatal(err)
	}
	s.hash = refreshHash(token)
	w := refreshRequest(handler, fmt.Sprintf(`{"refresh_token":%q}`, token), "")
	if w.Code != 200 {
		t.Fatalf("legacy rejected %d %s", w.Code, w.Body.String())
	}
}

func TestRefreshCORSAndMethod(t *testing.T) {
	_, _, s, handler := refreshFixture(t, false)
	r := httptest.NewRequest("OPTIONS", "/api/v2/auth/tokens/current", nil)
	r.Header.Set("Origin", "https://app.example")
	r.Header.Set("Access-Control-Request-Method", "PATCH")
	r.Header.Set("Access-Control-Request-Headers", "content-type")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	if w.Code != 204 || w.Header().Get("Access-Control-Allow-Origin") != "https://app.example" || w.Header().Get("Access-Control-Allow-Credentials") != "true" || s.calls != 0 {
		t.Fatal("CORS preflight failed")
	}
	w = httptest.NewRecorder()
	handler.ServeHTTP(w, httptest.NewRequest("GET", "/api/v2/auth/tokens/current", nil))
	if w.Code != 405 || w.Header().Get("Allow") != "PATCH, DELETE, OPTIONS" {
		t.Fatal("wrong method")
	}
}

func TestRefreshFormBody(t *testing.T) {
	_, tokens, _, handler := refreshFixture(t, false)
	r := httptest.NewRequest("PATCH", "/api/v2/auth/tokens/current", strings.NewReader(url.Values{"refresh_token": {tokens["refresh-hs256"]}}.Encode()))
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	if w.Code != 200 {
		t.Fatalf("form rejected: %d %s", w.Code, w.Body.String())
	}
}

func TestRefreshSharedCredentialBody(t *testing.T) {
	data, err := os.ReadFile("../../contracts/scenarios/auth-refresh.json")
	if err != nil {
		t.Fatal(err)
	}
	var shared struct {
		RequestBodyCases []struct {
			ID, ContentType, Body, Cookie string
			Bytes                         int
			Accepted                      bool
		}
	}
	if err := json.Unmarshal(data, &shared); err != nil {
		t.Fatal(err)
	}
	if len(shared.RequestBodyCases) != 12 {
		t.Fatal("expected all common request cases")
	}
	for _, item := range shared.RequestBodyCases {
		t.Run(item.ID, func(t *testing.T) {
			_, tokens, store, handler := refreshFixture(t, false)
			token := tokens["refresh-hs256"]
			body := strings.ReplaceAll(item.Body, "TOKEN", token)
			if item.Bytes > len(body) {
				body += strings.Repeat(" ", item.Bytes-len(body))
			}
			r := httptest.NewRequest("PATCH", "/api/v2/auth/tokens/current", strings.NewReader(body))
			r.Header.Set("Content-Type", item.ContentType)
			if item.Cookie != "" {
				r.Header.Set("Cookie", "refresh_token="+strings.ReplaceAll(item.Cookie, "TOKEN", token))
			}
			w := httptest.NewRecorder()
			handler.ServeHTTP(w, r)
			status, cookies, calls := 401, 0, 0
			if item.Accepted {
				status, cookies, calls = 200, 2, 1
			}
			if w.Code != status || len(w.Result().Cookies()) != cookies || store.calls != calls {
				t.Fatalf("status=%d, cookies=%d, rotations=%d", w.Code, len(w.Result().Cookies()), store.calls)
			}
		})
	}
}

func TestRefreshRejectsTextBodyAndDuplicateFormFields(t *testing.T) {
	for _, tc := range []struct{ name, contentType string }{
		{"text", "text/plain"},
		{"text with parameters", "text/plain; charset=utf-8"},
		{"duplicate form field", "application/x-www-form-urlencoded"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, tokens, store, handler := refreshFixture(t, false)
			body := fmt.Sprintf(`{"refresh_token":%q}`, tokens["refresh-hs256"])
			if tc.name == "duplicate form field" {
				body = url.Values{"refresh_token": {tokens["refresh-hs256"], tokens["refresh-hs256"]}}.Encode()
			}
			r := httptest.NewRequest("PATCH", "/api/v2/auth/tokens/current", strings.NewReader(body))
			r.Header.Set("Content-Type", tc.contentType)
			w := httptest.NewRecorder()
			handler.ServeHTTP(w, r)
			if w.Code != 401 || store.calls != 0 {
				t.Fatalf("unexpected status %d or store calls %d", w.Code, store.calls)
			}
		})
	}
}

func TestRefreshOverLoopbackHTTP(t *testing.T) {
	_, tokens, _, handler := refreshFixture(t, false)
	srv := httptest.NewServer(handler)
	defer srv.Close()
	req, err := http.NewRequest("PATCH", srv.URL+"/api/v2/auth/tokens/current", strings.NewReader(fmt.Sprintf(`{"refresh_token":%q}`, tokens["refresh-hs256"])))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Origin", "https://app.example")
	resp, err := srv.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 || resp.Header.Get("Access-Control-Allow-Origin") != "https://app.example" || resp.Header.Get("Access-Control-Allow-Credentials") != "true" || len(resp.Cookies()) != 2 {
		t.Fatalf("loopback HTTP status %d", resp.StatusCode)
	}
}
