package server

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type session struct {
	user             int64
	id, jti          string
	revoked, expired bool
}
type memorySessions struct {
	rows                []session
	touches, revokes    int
	touchErr, revokeErr bool
}

func (s *memorySessions) Touch(_ context.Context, c auth.Claims) (int64, error) {
	s.touches++
	if s.touchErr {
		return 0, errors.New("private database detail")
	}
	for _, r := range s.rows {
		if r.user == c.UserID && r.id == c.SessionID && r.jti == c.JTI && !r.revoked && !r.expired {
			return 1, nil
		}
	}
	return 0, nil
}
func (s *memorySessions) Revoke(_ context.Context, u int64, id string) (int64, error) {
	return s.revoke(u, id, false)
}
func (s *memorySessions) RevokeOthers(_ context.Context, u int64, id string) (int64, error) {
	return s.revoke(u, id, true)
}
func (s *memorySessions) revoke(u int64, id string, others bool) (int64, error) {
	s.revokes++
	if s.revokeErr {
		return 0, errors.New("private database detail")
	}
	var n int64
	for i := range s.rows {
		r := &s.rows[i]
		if r.user == u && !r.revoked && ((others && r.id != id) || (!others && r.id == id)) {
			r.revoked = true
			n++
		}
	}
	return n, nil
}
func fixture(t *testing.T) (*auth.TokenManager, map[string]string) {
	t.Helper()
	b, e := os.ReadFile("../../contracts/scenarios/auth-tokens.json")
	if e != nil {
		t.Fatal(e)
	}
	var f struct {
		Keys  struct{ Access, Refresh string }
		Cases []struct{ ID, Token string }
	}
	if e = json.Unmarshal(b, &f); e != nil {
		t.Fatal(e)
	}
	c, e := auth.NewTokenManager([]byte(f.Keys.Access), []byte(f.Keys.Refresh), func() time.Time { return time.Unix(1700000000, 0) })
	if e != nil {
		t.Fatal(e)
	}
	m := map[string]string{}
	for _, x := range f.Cases {
		m[x.ID] = x.Token
	}
	return c, m
}
func store() *memorySessions {
	return &memorySessions{rows: []session{{42, "fixture-session-42", "fixture-access-jti-42", false, false}, {42, "peer", "peer-jti", false, false}, {42, "expired", "old", false, true}, {9, "foreign", "foreign", false, false}, {42, "revoked", "old", true, false}}}
}
func request(t *testing.T, client *http.Client, base, method, path, header, cookie string) (*http.Response, map[string]interface{}) {
	t.Helper()
	r, e := http.NewRequest(method, base+path, nil)
	if e != nil {
		t.Fatal(e)
	}
	if header != "" {
		r.Header.Set("Authorization", header)
	}
	if cookie != "" {
		r.Header.Set("Cookie", cookie)
	}
	resp, e := client.Do(r)
	if e != nil {
		t.Fatal(e)
	}
	defer resp.Body.Close()
	b, e := io.ReadAll(resp.Body)
	if e != nil {
		t.Fatal(e)
	}
	var body map[string]interface{}
	_ = json.Unmarshal(b, &body)
	return resp, body
}
func TestHTTPRevocation(t *testing.T) {
	codec, tokens := fixture(t)
	for _, tc := range []struct {
		name, path, token, cookie string
		status, touches, revokes  int
		count                     float64
		clear                     bool
		touchErr, revokeErr       bool
	}{
		{name: "missing", path: "peer", status: 401}, {name: "invalid", path: "peer", token: "wrong-key", status: 401},
		{name: "cookie-priority", path: "peer", token: "access-hs256", cookie: "access_token=bad", status: 401},
		{name: "peer", path: "peer", token: "access-hs256", status: 200, touches: 1, revokes: 1},
		{name: "expired-peer", path: "expired", token: "access-hs256", status: 200, touches: 1, revokes: 1},
		{name: "foreign", path: "foreign", token: "access-hs256", status: 404, touches: 1, revokes: 1},
		{name: "already-revoked", path: "revoked", token: "access-hs256", status: 404, touches: 1, revokes: 1},
		{name: "raw-id", path: "%70eer", token: "access-hs256", status: 404, touches: 1, revokes: 1},
		{name: "encoded-others", path: "%6fthers", token: "access-hs256", status: 404, touches: 1, revokes: 1},
		{name: "self", path: "fixture-session-42", token: "access-hs256", status: 200, touches: 1, revokes: 1, clear: true},
		{name: "others", path: "others", token: "access-hs256", status: 200, touches: 1, revokes: 1, count: 2},
		{name: "touch-error", path: "peer", token: "access-hs256", status: 401, touches: 1, touchErr: true},
		{name: "revoke-error", path: "peer", token: "access-hs256", status: 500, touches: 1, revokes: 1, revokeErr: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := store()
			s.touchErr = tc.touchErr
			s.revokeErr = tc.revokeErr
			ts := httptest.NewServer(NewHandler(codec, s, CorsPolicy{}))
			defer ts.Close()
			header := ""
			if tc.token != "" {
				header = "bEaReR  " + tokens[tc.token]
			}
			resp, body := request(t, ts.Client(), ts.URL, "DELETE", "/api/v2/auth/sessions/"+tc.path, header, tc.cookie)
			if resp.StatusCode != tc.status {
				t.Fatalf("status %d, want %d; body %v", resp.StatusCode, tc.status, body)
			}
			if s.touches != tc.touches || s.revokes != tc.revokes {
				t.Fatalf("calls %d/%d", s.touches, s.revokes)
			}
			if strings.Contains(bodyString(body), "private") {
				t.Fatal("leaked DB detail")
			}
			if (len(resp.Cookies()) == 2) != tc.clear {
				t.Fatalf("cookies %v", resp.Cookies())
			}
			if tc.clear {
				for _, c := range resp.Cookies() {
					if c.Value != "" || c.Path != "/" || c.MaxAge != -1 {
						t.Fatal(c)
					}
				}
				r, _ := request(t, ts.Client(), ts.URL, "DELETE", "/api/v2/auth/sessions/peer", header, "")
				if r.StatusCode != 401 {
					t.Fatalf("revoked token accepted: %d", r.StatusCode)
				}
			}
			if tc.path == "others" && tc.status == 200 {
				if body["data"].(map[string]interface{})["revoked_count"] != tc.count {
					t.Fatal(body)
				}
			}
		})
	}
}
func bodyString(b map[string]interface{}) string { v, _ := json.Marshal(b); return string(v) }
func TestNativeNoFallbackOrMethodEffects(t *testing.T) {
	c, _ := fixture(t)
	s := store()
	ts := httptest.NewServer(NewHandler(c, s, CorsPolicy{}))
	defer ts.Close()
	for _, p := range []string{"/storage/x", "/api/v2/auth/sessions/peer", "/api/v2/ws", "/api/v2/auth/login"} {
		r, _ := request(t, ts.Client(), ts.URL, "GET", p, "", "")
		if r.StatusCode < 400 {
			t.Fatal(r.StatusCode)
		}
	}
	if s.touches+s.revokes != 0 {
		t.Fatal("unexpected database call")
	}
	r, _ := request(t, ts.Client(), ts.URL, "GET", "/api/health", "", "")
	if r.StatusCode != 200 {
		t.Fatal(r.StatusCode)
	}
}
func TestCORSBeforeAuth(t *testing.T) {
	c, _ := fixture(t)
	s := store()
	ts := httptest.NewServer(NewHandler(c, s, CorsPolicy{Origins: []string{"https://app.example"}}))
	defer ts.Close()
	for _, tc := range []struct {
		origin, method, headers string
		status                  int
	}{{"https://app.example", "DELETE", "Authorization, x-device-info,x-request-id", 204}, {"https://evil.example", "DELETE", "", 403}, {"https://app.example", "TRACE", "", 403}, {"https://app.example", "DELETE", "x-unknown", 403}, {"", "", "", 204}} {
		r, _ := http.NewRequest("OPTIONS", ts.URL+"/api/v2/auth/sessions/peer", nil)
		r.Header.Set("Origin", tc.origin)
		r.Header.Set("Access-Control-Request-Method", tc.method)
		r.Header.Set("Access-Control-Request-Headers", tc.headers)
		resp, e := ts.Client().Do(r)
		if e != nil {
			t.Fatal(e)
		}
		resp.Body.Close()
		if resp.StatusCode != tc.status {
			t.Fatalf("%+v: %d", tc, resp.StatusCode)
		}
		if !strings.Contains(resp.Header.Get("Vary"), "Origin") {
			t.Fatal("missing Vary")
		}
	}
	if s.touches+s.revokes != 0 {
		t.Fatal("CORS touched database")
	}
}
