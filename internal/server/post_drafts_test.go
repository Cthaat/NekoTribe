package server

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPostDraftRoutesRequireAccess(t *testing.T) {
	handler := NewHandler(nil, nil, CorsPolicy{})
	const base = "/api/v2/users/me/drafts"
	for _, route := range []struct{ method, suffix string }{
		{http.MethodGet, ""}, {http.MethodPost, ""},
		{http.MethodPut, "/12"}, {http.MethodDelete, "/12"},
		{http.MethodPut, "/12/schedule"}, {http.MethodDelete, "/12/schedule"},
		{http.MethodPost, "/12/publish"},
	} {
		res := httptest.NewRecorder()
		handler.ServeHTTP(res, httptest.NewRequest(route.method, base+route.suffix, nil))
		if res.Code != http.StatusUnauthorized || res.Header().Get("Cache-Control") != "private, no-store" {
			t.Errorf("%s %s returned %d: %s", route.method, route.suffix, res.Code, res.Body)
		}
	}
}

func TestPostDraftPayloadScopesAndSchedule(t *testing.T) {
	for _, tc := range []struct {
		body  string
		valid bool
	}{
		{`{"group_id":null,"content":"","location":"","media_ids":[7],"tag_names":["draft"]}`, true},
		{`{"group_id":7,"content":"  ","media_urls":[" /upload/foo "],"is_announcement":false}`, true},
		{`{"group_id":9007199254740991,"content":""}`, true},
		{`{"group_id":null,"content":"hello","visibility":"unlisted"}`, false},
		{`{"group_id":7,"content":"hello","media_ids":[7]}`, false},
		{`{"group_id":null,"content":"hello","is_announcement":false}`, false},
		{`{"group_id":null,"content":"hello","media_ids":[null]}`, false},
		{`{"group_id":0,"content":""}`, false},
		{`{"group_id":9007199254740992,"content":""}`, false},
		{`{"content":""}`, false},
		{`{"group_id":null,"content":"","location":"` + strings.Repeat("猫", 34) + `"}`, false},
	} {
		_, err := parsePostDraft([]byte(tc.body))
		if (err == nil) != tc.valid {
			t.Errorf("parsePostDraft(%s) returned %v", tc.body, err)
		}
	}
	query, err := parsePostDraftQuery("group_id=0&before_id=12&limit=5")
	if err != nil || query.group == nil || *query.group != 0 || query.before == nil || *query.before != 12 || query.limit != 5 {
		t.Fatalf("unexpected draft query %+v with error %v", query, err)
	}
	for _, raw := range []string{"group_id=00", "before_id=0", "limit=51", "limit=2&limit=2"} {
		if _, err := parsePostDraftQuery(raw); !errors.Is(err, errPostDraftInvalid) {
			t.Fatalf("accepted draft query %s", raw)
		}
	}
	at, err := parsePostDraftSchedule([]byte(`{"scheduled_at":"2026-12-01T10:25:30.98765+08:00"}`))
	if err != nil || at.Format(postUTCDateLayout) != "2026-12-01T02:25:30.987Z" {
		t.Fatalf("invalid normalized schedule %v, err %v", at, err)
	}
	if _, err := parsePostDraftSchedule([]byte(`{"scheduled_at":"2026-11-31T10:25:30Z"}`)); !errors.Is(err, errPostDraftInvalid) {
		t.Fatalf("accepted invalid schedule date: %v", err)
	}
}
