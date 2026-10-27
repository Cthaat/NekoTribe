package server

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type loginFixtureStore struct {
	*rotationStore
	account                                                           LoginAccount
	exists, twoFactor, profileOK, insertFail, profileFail, schemaFail bool
	inserted                                                          []LoginSession
	updateCount                                                       int
	known, alertFail                                                  bool
	alertCount                                                        int
}

func (s *loginFixtureStore) LookupLogin(_ context.Context, account string) (LoginAccount, bool, error) {
	return s.account, s.exists && (account == s.account.Username || account == "fake@example.test"), nil
}
func (s *loginFixtureStore) TwoFactorEnabled(context.Context, int64) (bool, error) {
	return s.twoFactor, nil
}
func (s *loginFixtureStore) CheckTwoFactorSchema(context.Context) error {
	if s.schemaFail {
		return errSessionStore
	}
	return nil
}
func (s *loginFixtureStore) InsertLoginSession(_ context.Context, v LoginSession) error {
	if s.insertFail {
		return errSessionStore
	}
	s.inserted = append(s.inserted, v)
	return nil
}
func (s *loginFixtureStore) UpdateLastLogin(context.Context, int64) error {
	s.updateCount++
	return nil
}
func (s *loginFixtureStore) SelfProfile(context.Context, int64) (SelfUser, bool, error) {
	if s.profileFail {
		return SelfUser{}, false, errSessionStore
	}
	return SelfUser{UserID: s.account.UserID, Username: s.account.Username}, s.profileOK, nil
}
func (s *loginFixtureStore) KnownLoginDevice(context.Context, int64, string) (bool, error) {
	return s.known, nil
}
func (s *loginFixtureStore) RecordLoginAlert(context.Context, LoginSession) error {
	s.alertCount++
	if s.alertFail {
		return errSessionStore
	}
	return nil
}

func newLoginFixture(t *testing.T) (*loginFixtureStore, http.Handler, *auth.TokenManager) {
	t.Helper()
	codec, _, rotation, _ := refreshFixture(t, false)
	s := &loginFixtureStore{rotationStore: rotation, account: LoginAccount{UserID: 42, Username: "tester", PasswordHash: "$2b$04$abcdefghijklmnopqrstuunCb8AcUlO2CukFVuQ5U9hCvDhIsHd22", Status: "active", Active: true}, exists: true, profileOK: true}
	return s, NewHandlerWithConfig(codec, s, CorsPolicy{}, RefreshConfig{AccessSeconds: 900, RefreshSeconds: 3600, clock: func() time.Time { return time.Unix(1700000000, 123000000) }}), codec
}
func loginRequest(h http.Handler, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(http.MethodPost, "/api/v2/auth/tokens", strings.NewReader(body))
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func TestSharedBcryptLoginVectors(t *testing.T) {
	bytes, err := os.ReadFile("../../contracts/scenarios/auth-bcrypt.json")
	if err != nil {
		t.Fatal(err)
	}
	var data struct {
		Cases []struct {
			ID, Password, Hash string
			Valid              bool
		}
	}
	if err = json.Unmarshal(bytes, &data); err != nil {
		t.Fatal(err)
	}
	for _, v := range data.Cases {
		t.Run(v.ID, func(t *testing.T) {
			if got := matchesLoginPassword(v.Hash, v.Password); got != v.Valid {
				t.Fatalf("valid=%v expected=%v", got, v.Valid)
			}
		})
	}
}
func TestLoginIssuesSessionAndMatchingCookie(t *testing.T) {
	s, h, codec := newLoginFixture(t)
	w := loginRequest(h, `{"account":"fake@example.test","password":"synthetic-password","remember_me":true}`)
	if w.Code != 200 || len(s.inserted) != 1 || s.updateCount != 1 || s.alertCount != 1 {
		t.Fatalf("status %d sessions %d updates %d", w.Code, len(s.inserted), s.updateCount)
	}
	var payload struct {
		Data struct {
			Tokens struct {
				SessionID    string `json:"session_id"`
				AccessToken  string `json:"access_token"`
				RefreshToken string `json:"refresh_token"`
			} `json:"tokens"`
		} `json:"data"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	sess := s.inserted[0]
	if sess.SessionID != payload.Data.Tokens.SessionID || sess.RefreshHash != refreshHash(payload.Data.Tokens.RefreshToken) || sess.DeviceInfo != "unknown" || sess.DeviceFingerprint != "unknown" {
		t.Fatal("session data mismatch")
	}
	claims, err := codec.Verify(payload.Data.Tokens.AccessToken, auth.Access)
	if err != nil || claims.JTI != sess.AccessJTI {
		t.Fatal("access claims mismatch")
	}
	cookies := w.Result().Cookies()
	if len(cookies) != 2 {
		t.Fatalf("cookies %d", len(cookies))
	}
	for _, c := range cookies {
		if !c.HttpOnly || c.Path != "/" || c.SameSite != http.SameSiteLaxMode || (c.Name == "access_token" && c.Value != payload.Data.Tokens.AccessToken) || (c.Name == "refresh_token" && c.Value != payload.Data.Tokens.RefreshToken) {
			t.Fatal("cookie mismatch")
		}
	}
}
func TestLoginRejectsInvalidAndFailsClosedForTwoFactor(t *testing.T) {
	for _, tc := range []struct {
		name, body string
		status     int
		mutate     func(*loginFixtureStore)
	}{
		{"missing account", `{"password":"x"}`, 400, func(*loginFixtureStore) {}},
		{"unknown", `{"account":"unknown","password":"synthetic-password"}`, 401, func(*loginFixtureStore) {}},
		{"bad password", `{"account":"tester","password":"wrong"}`, 401, func(*loginFixtureStore) {}},
		{"disabled", `{"account":"tester","password":"synthetic-password"}`, 403, func(s *loginFixtureStore) { s.account.Active = false }},
		{"two factor unsupported", `{"account":"tester","password":"synthetic-password"}`, 503, func(s *loginFixtureStore) { s.twoFactor = true }},
		{"schema missing", `{"account":"tester","password":"synthetic-password"}`, 503, func(s *loginFixtureStore) { s.schemaFail = true }},
		{"storage fails", `{"account":"tester","password":"synthetic-password"}`, 500, func(s *loginFixtureStore) { s.insertFail = true }},
		{"profile fails", `{"account":"tester","password":"synthetic-password"}`, 500, func(s *loginFixtureStore) { s.profileFail = true }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s, h, _ := newLoginFixture(t)
			tc.mutate(s)
			w := loginRequest(h, tc.body)
			if w.Code != tc.status || len(w.Result().Cookies()) != 0 {
				t.Fatalf("status=%d cookies=%d", w.Code, len(w.Result().Cookies()))
			}
			if tc.name == "profile fails" && len(s.inserted) != 1 {
				t.Fatal("session may already be committed")
			}
			if strings.Contains(w.Body.String(), s.account.PasswordHash) {
				t.Fatal("password hash leaked")
			}
		})
	}
}
func TestLoginBcryptLongInputTruncatesBytes(t *testing.T) {
	input := strings.Repeat("猫", 24) + "extra"
	if !matchesLoginPassword("$2b$04$abcdefghijklmnopqrstuujEsKaymP7pmlER4.gAB8JDUMo3GAzey", input) {
		t.Fatal(fmt.Sprintf("UTF-8 byte truncation failed (%d bytes)", len(input)))
	}
}

func TestLoginAlertIsBestEffortAndOnlyForNewDevice(t *testing.T) {
	for _, tc := range []struct {
		name        string
		known, fail bool
		expected    int
	}{{"new", false, false, 1}, {"known", true, false, 0}, {"alert error", false, true, 1}} {
		t.Run(tc.name, func(t *testing.T) {
			s, h, _ := newLoginFixture(t)
			s.known = tc.known
			s.alertFail = tc.fail
			w := loginRequest(h, `{"account":"tester","password":"synthetic-password"}`)
			if w.Code != 200 || s.alertCount != tc.expected || len(w.Result().Cookies()) != 2 {
				t.Fatal("login alert changed authentication outcome")
			}
		})
	}
}

func TestLoginUsesJavascriptTrimForUnicodeWhitespace(t *testing.T) {
	_, h, _ := newLoginFixture(t)
	if got := loginRequest(h, `{"account":"\ufefftester\ufeff","password":"\ufeffsynthetic-password\ufeff"}`); got.Code != 200 {
		t.Fatalf("FEFF should trim: %d", got.Code)
	}
	if got := loginRequest(h, `{"account":"\u0085tester","password":"synthetic-password"}`); got.Code != 401 {
		t.Fatalf("U+0085 should not trim: %d", got.Code)
	}
	if got := loginRequest(h, `{"account":"tester","password":"\u0085synthetic-password"}`); got.Code != 401 {
		t.Fatalf("U+0085 password should not trim: %d", got.Code)
	}
}

func TestLoginIPOnlyUsesForwardedHeaderWhenTrusted(t *testing.T) {
	for _, tc := range []struct {
		trusted  bool
		expected string
	}{{false, "192.0.2.1"}, {true, "203.0.113.8"}} {
		s, _, codec := newLoginFixture(t)
		h := NewHandlerWithConfig(codec, s, CorsPolicy{}, RefreshConfig{AccessSeconds: 900, RefreshSeconds: 3600, TrustProxy: tc.trusted, clock: func() time.Time { return time.Unix(1700000000, 0) }})
		r := httptest.NewRequest("POST", "/api/v2/auth/tokens", strings.NewReader(`{"account":"tester","password":"synthetic-password"}`))
		r.Header.Set("Content-Type", "application/json")
		r.RemoteAddr = "192.0.2.1:1234"
		r.Header.Set("X-Forwarded-For", " 203.0.113.8, 10.0.0.1")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != 200 || len(s.inserted) != 1 || s.inserted[0].IPAddress != tc.expected {
			t.Fatalf("trusted=%v status=%d", tc.trusted, w.Code)
		}
	}
}
