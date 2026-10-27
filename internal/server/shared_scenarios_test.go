package server

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"
)

type scenarioSession struct {
	SessionID       string `json:"sessionId"`
	UserID          int64  `json:"userId"`
	AccessJTI       string `json:"accessJti"`
	AccessExpiresAt int64
	RevokedAt       *int64
	LastAccessedAt  int64
}
type scenarioStore struct {
	sessions         []scenarioSession
	now              int64
	fault            string
	touches, revokes int
}

func (s *scenarioStore) Touch(_ context.Context, c auth.Claims) (int64, error) {
	s.touches++
	if s.fault == "touch" {
		return 0, errors.New("synthetic private driver detail")
	}
	for i := range s.sessions {
		r := &s.sessions[i]
		if r.UserID == c.UserID && r.SessionID == c.SessionID && r.AccessJTI == c.JTI && r.RevokedAt == nil && r.AccessExpiresAt > s.now {
			r.LastAccessedAt = s.now
			return 1, nil
		}
	}
	return 0, nil
}
func (s *scenarioStore) Revoke(_ context.Context, u int64, id string) (int64, error) {
	return s.revoke(u, id, false)
}
func (s *scenarioStore) RevokeOthers(_ context.Context, u int64, id string) (int64, error) {
	return s.revoke(u, id, true)
}
func (s *scenarioStore) revoke(u int64, id string, others bool) (int64, error) {
	s.revokes++
	if s.fault == "revoke" {
		return 0, errors.New("synthetic private driver detail")
	}
	var n int64
	for i := range s.sessions {
		r := &s.sessions[i]
		if r.UserID == u && r.RevokedAt == nil && ((others && r.SessionID != id) || (!others && r.SessionID == id)) {
			now := s.now
			r.RevokedAt = &now
			n++
		}
	}
	return n, nil
}
func TestSharedSessionScenarios(t *testing.T) {
	b, e := os.ReadFile("../../contracts/scenarios/auth-session-revocation.json")
	if e != nil {
		t.Fatal(e)
	}
	var f struct {
		Now   int64
		Keys  struct{ Access, Refresh string }
		Cases []struct {
			ID, Fault string
			Sessions  []scenarioSession
			Requests  []struct {
				Method, Path           string
				Headers                map[string]string
				CookieFields           []string
				ExpectedStatus         int
				ExpectedEnvelope       json.RawMessage
				ExpectedClearedCookies []string
			}
			ExpectedTouches, ExpectedRevokes                     int
			ExpectedRevokedSessionIDs, ExpectedTouchedSessionIDs []string
		}
	}
	if e = json.Unmarshal(b, &f); e != nil {
		t.Fatal(e)
	}
	codec, e := auth.NewTokenManager([]byte(f.Keys.Access), []byte(f.Keys.Refresh), func() time.Time { return time.Unix(f.Now, 0) })
	if e != nil {
		t.Fatal(e)
	}
	for _, tc := range f.Cases {
		t.Run(tc.ID, func(t *testing.T) {
			s := &scenarioStore{sessions: tc.Sessions, now: f.Now, fault: tc.Fault}
			ts := httptest.NewServer(NewHandler(codec, s, CorsPolicy{}))
			defer ts.Close()
			for _, rq := range tc.Requests {
				req, e := http.NewRequest(rq.Method, ts.URL+rq.Path, nil)
				if e != nil {
					t.Fatal(e)
				}
				for k, v := range rq.Headers {
					req.Header.Set(k, v)
				}
				for _, value := range rq.CookieFields {
					req.Header.Add("Cookie", value)
				}
				resp, e := ts.Client().Do(req)
				if e != nil {
					t.Fatal(e)
				}
				body, e := io.ReadAll(resp.Body)
				resp.Body.Close()
				if e != nil {
					t.Fatal(e)
				}
				if resp.StatusCode != rq.ExpectedStatus {
					t.Fatalf("status %d want %d body %s", resp.StatusCode, rq.ExpectedStatus, body)
				}
				if len(rq.ExpectedEnvelope) > 0 {
					var actual, expected interface{}
					if e = json.Unmarshal(body, &actual); e != nil {
						t.Fatal(e)
					}
					_ = json.Unmarshal(rq.ExpectedEnvelope, &expected)
					if !reflect.DeepEqual(actual, expected) {
						t.Fatalf("envelope %s want %s", body, rq.ExpectedEnvelope)
					}
				} else if strings.Contains(string(body), "private") {
					t.Fatal("unsafe error")
				}
				names := []string{}
				for _, c := range resp.Cookies() {
					if c.Value == "" && c.Path == "/" && c.MaxAge == -1 {
						names = append(names, c.Name)
					} else {
						t.Fatalf("unexpected cookie %v", c)
					}
				}
				sort.Strings(names)
				sort.Strings(rq.ExpectedClearedCookies)
				if !reflect.DeepEqual(names, rq.ExpectedClearedCookies) {
					t.Fatalf("cookies %v want %v", names, rq.ExpectedClearedCookies)
				}
			}
			if s.touches != tc.ExpectedTouches || s.revokes != tc.ExpectedRevokes {
				t.Fatalf("calls %d/%d want %d/%d", s.touches, s.revokes, tc.ExpectedTouches, tc.ExpectedRevokes)
			}
			revoked, touched := []string{}, []string{}
			for _, r := range s.sessions {
				if r.RevokedAt != nil {
					revoked = append(revoked, r.SessionID)
				}
				if r.LastAccessedAt == f.Now {
					touched = append(touched, r.SessionID)
				}
			}
			sort.Strings(revoked)
			sort.Strings(touched)
			if !reflect.DeepEqual(revoked, tc.ExpectedRevokedSessionIDs) || !reflect.DeepEqual(touched, tc.ExpectedTouchedSessionIDs) {
				t.Fatalf("state revoked=%v touched=%v", revoked, touched)
			}
		})
	}
}
