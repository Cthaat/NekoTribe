package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
)

func TestPostPollRoutesApplyAuthentication(t *testing.T) {
	handler := NewHandler(nil, nil, CorsPolicy{})
	for _, tc := range []struct {
		method, path string
		status       int
	}{
		{http.MethodGet, "/api/v2/posts/4/poll", http.StatusServiceUnavailable},
		{http.MethodGet, "/api/v2/groups/2/posts/4/poll", http.StatusUnauthorized},
		{http.MethodPost, "/api/v2/posts/4/poll/vote", http.StatusUnauthorized},
		{http.MethodPost, "/api/v2/groups/2/posts/4/poll/vote", http.StatusUnauthorized},
	} {
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, httptest.NewRequest(tc.method, tc.path, strings.NewReader(`{"option_ids":[1]}`)))
		if recorder.Code != tc.status || recorder.Header().Get("Cache-Control") != "private, no-store" {
			t.Errorf("%s %s: status %d, headers %+v, response %s", tc.method, tc.path, recorder.Code, recorder.Header(), recorder.Body)
		}
	}
}

func TestPostCreateRejectsPollWithPostReference(t *testing.T) {
	body := map[string]interface{}{
		"content": "post",
		"poll": map[string]interface{}{
			"options":   []interface{}{"first", "second"},
			"multiple":  false,
			"closes_at": "2026-12-01T00:00:00Z",
		},
		"reply_to_post_id": float64(4),
	}
	if _, message := readPostCreateInput(body, nil); message == "" {
		t.Fatal("accepted a reply with an attached poll")
	}
}

func TestPostPollCreationMatchesBothPostParsers(t *testing.T) {
	const closes = "2026-12-01T11:22:33.987654+08:00"
	const normalized = "2026-12-01T03:22:33.987Z"
	validOption := strings.Repeat("猫", 80)
	for _, tc := range []struct {
		name, poll string
		valid      bool
	}{
		{"valid", `{"options":["  first  ","` + validOption + `"],"multiple":true,"closes_at":"` + closes + `"}`, true},
		{"duplicate", `{"options":["first"," first "],"multiple":true,"closes_at":"` + closes + `"}`, false},
		{"byte limit", `{"options":["first","` + validOption + `a"],"multiple":true,"closes_at":"` + closes + `"}`, false},
		{"blank", `{"options":["first","\t"],"multiple":true,"closes_at":"` + closes + `"}`, false},
		{"too few", `{"options":["first"],"multiple":true,"closes_at":"` + closes + `"}`, false},
		{"too many", `{"options":["a","b","c","d","e","f","g"],"multiple":true,"closes_at":"` + closes + `"}`, false},
		{"option type", `{"options":["first",false],"multiple":true,"closes_at":"` + closes + `"}`, false},
		{"multiple type", `{"options":["a","b"],"multiple":null,"closes_at":"` + closes + `"}`, false},
		{"date format", `{"options":["a","b"],"multiple":true,"closes_at":"2026-12-01 03:22:33"}`, false},
		{"calendar", `{"options":["a","b"],"multiple":true,"closes_at":"2026-11-31T03:22:33Z"}`, false},
		{"null", `null`, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			raw := `{"content":"hello","poll":` + tc.poll + `}`
			req := httptest.NewRequest(http.MethodPost, "/api/v2/posts", strings.NewReader(raw))
			body, ok := readPostCreateBody(req)
			if !ok {
				t.Fatal("invalid creation fixture")
			}
			regular, bad := readPostCreateInput(body, nil)
			group := groupPostMutation{action: "create"}
			groupBad := parseGroupPostMutation([]byte(raw), &group)
			if (bad == "") != tc.valid || (groupBad == "") != tc.valid {
				t.Fatalf("regular failure %q, group failure %q", bad, groupBad)
			}
			if !tc.valid {
				return
			}
			for _, poll := range []*postPollCreation{regular.Poll, group.poll} {
				if poll == nil || !poll.multiple || poll.closesAt.Format("2006-01-02T15:04:05.000Z") != normalized ||
					!slices.Equal(poll.options, []string{"first", validOption}) {
					t.Fatalf("unexpected poll %+v", poll)
				}
			}
		})
	}
}

func TestPostPollVoteBody(t *testing.T) {
	if ids, err := parsePostPollChoices([]byte(`{"option_ids":[1.0,6]}`)); err != nil || !slices.Equal(ids, []int64{1, 6}) {
		t.Fatalf("option IDs %v with error %v", ids, err)
	}
	for _, raw := range []string{
		`null`, `[1]`, `{}`, `{"option_ids":null}`, `{"option_ids":[]}`, `{"option_ids":[1,1]}`,
		`{"option_ids":["1"]}`, `{"option_ids":[false]}`, `{"option_ids":[1.5]}`, `{"option_ids":[7]}`,
		`{"option_ids":[0]}`, `{"option_ids":[1],"extra":true}`,
	} {
		if ids, err := parsePostPollChoices([]byte(raw)); err == nil {
			t.Fatalf("accepted %s as %v", raw, ids)
		}
	}
}

func TestPostPollIsOptionalOnPostResponses(t *testing.T) {
	for _, value := range []any{PostDetail{}, groupPost{}} {
		body, err := json.Marshal(value)
		if err != nil || strings.Contains(string(body), `"poll"`) {
			t.Fatalf("poll appeared on ordinary post %v: %s", err, body)
		}
	}
}
