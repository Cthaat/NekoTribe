package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

func TestSharedSessionPagination(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/auth-session-pagination.json")
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Cases []struct {
			ID, Query  string
			Page       float64
			PageSize   float64 `json:"page_size"`
			Start, End float64
		}
	}
	if err = json.Unmarshal(raw, &f); err != nil || len(f.Cases) != 16 {
		t.Fatal("invalid fixtures", err)
	}
	for _, c := range f.Cases {
		t.Run(c.ID, func(t *testing.T) {
			got := sessionPagination(parseSessionQuery(c.Query))
			if got.Page != c.Page || got.PageSize != c.PageSize || got.Start != c.Start || got.End != c.End {
				t.Fatalf("got %+v", got)
			}
		})
	}
}

type listFixture struct {
	*memorySessions
	called int
	fail   bool
	user   int64
	page   SessionPage
}

func (s *listFixture) ListSessions(_ context.Context, user int64, p SessionPage) ([]SessionItem, int64, error) {
	s.called++
	s.user = user
	s.page = p
	if s.fail {
		return nil, 0, errors.New("private database secret")
	}
	return []SessionItem{{SessionID: "fixture-session-42", DeviceInfo: "device", IPAddress: "127.0.0.1", LastAccessedAt: "2026-01-01T00:00:00.000Z", CreatedAt: ""}}, 3, nil
}

func TestSessionListAuthenticationAndResponse(t *testing.T) {
	codec, tokens := fixture(t)
	for _, tc := range []struct {
		name, auth, cookie string
		fail               bool
		status, calls      int
	}{
		{name: "valid", auth: tokens["access-hs256"], status: 200, calls: 1},
		{name: "missing", status: 401},
		{name: "bad-cookie", auth: tokens["access-hs256"], cookie: "access_token=bad", status: 401},
		{name: "store-failure", auth: tokens["access-hs256"], fail: true, status: 500, calls: 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			store := &listFixture{memorySessions: store(), fail: tc.fail}
			req := httptest.NewRequest("GET", "/api/v2/auth/sessions?page=2&page_size=1", nil)
			if tc.auth != "" {
				req.Header.Set("Authorization", "Bearer "+tc.auth)
			}
			if tc.cookie != "" {
				req.Header.Set("Cookie", tc.cookie)
			}
			res := httptest.NewRecorder()
			NewHandler(codec, store, CorsPolicy{}).ServeHTTP(res, req)
			if res.Code != tc.status || store.called != tc.calls || strings.Contains(res.Body.String(), "private") {
				t.Fatalf("status=%d calls=%d body=%s", res.Code, store.called, res.Body.String())
			}
			if tc.status != 200 {
				return
			}
			var body struct {
				Data []SessionItem `json:"data"`
				Meta struct {
					Page, Total float64
					PageSize    float64 `json:"page_size"`
					HasNext     bool    `json:"has_next"`
				} `json:"meta"`
			}
			if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
				t.Fatal(err)
			}
			if store.user != 42 || store.page.Start != 2 || len(body.Data) != 1 || !body.Data[0].IsCurrent || body.Meta.Page != 2 || body.Meta.PageSize != 1 || body.Meta.Total != 3 || !body.Meta.HasNext {
				t.Fatalf("unexpected response %s", res.Body.String())
			}
		})
	}
}
