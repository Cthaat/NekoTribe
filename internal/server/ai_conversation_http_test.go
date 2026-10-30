package server

import (
	"context"
	"errors"
	"net/http/httptest"
	"strings"
	"testing"
)

type aiHTTPFixture struct {
	*memorySessions
	operation    string
	actor        int64
	after, limit int64
	content      string
	policy       moderationPolicy
	fail         error
}

func (s *aiHTTPFixture) createAIConversation(_ context.Context, user int64, input conversationInput, policy moderationPolicy) (conversationRecord, error) {
	s.operation = "create"
	s.actor = user
	s.policy = policy
	return conversationRecord{ID: "f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb", Purpose: input.Purpose}, s.fail
}
func (s *aiHTTPFixture) readAIConversation(_ context.Context, user int64, id string, policy moderationPolicy) (conversationRecord, error) {
	s.operation = "read"
	s.actor = user
	return conversationRecord{ID: id, Purpose: "knowledge"}, s.fail
}
func (s *aiHTTPFixture) appendAIUserMessage(_ context.Context, user int64, id, content string, policy moderationPolicy) (conversationMessage, error) {
	s.operation = "append"
	s.actor = user
	s.content = content
	return conversationMessage{ID: id, ConversationID: id, SequenceNo: 1, Role: "user"}, s.fail
}
func (s *aiHTTPFixture) listAIConversationMessages(_ context.Context, user int64, id string, after, limit int64, policy moderationPolicy) ([]conversationHistoryMessage, error) {
	s.operation = "list"
	s.actor = user
	s.after = after
	s.limit = limit
	return []conversationHistoryMessage{}, s.fail
}
func TestAIConversationHTTPRoutes(t *testing.T) {
	codec, tokens := fixture(t)
	id := "f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb"
	cases := []struct {
		method, path, body, operation string
		status                        int
	}{
		{"POST", "/api/v2/ai/conversations", `{"purpose":"knowledge"}`, "create", 200},
		{"GET", "/api/v2/ai/conversations/" + id, "", "read", 200},
		{"POST", "/api/v2/ai/conversations/" + id + "/messages", `{"content":"你好"}`, "append", 200},
		{"GET", "/api/v2/ai/conversations/" + id + "/messages?after_sequence=2&limit=10", "", "list", 200},
		{"POST", "/api/v2/ai/conversations/" + id + "/messages", `{"content":"x","role":"assistant"}`, "", 400},
		{"GET", "/api/v2/ai/conversations/" + id + "/messages?limit=51", "", "", 400},
		{"GET", "/api/v2/ai/conversations/" + id + "/messages?limit=1&limit=2", "", "", 400},
		{"GET", "/api/v2/ai/conversations/" + id + "/messages?limit=1e1", "", "", 400},
		{"POST", "/api/v2/ai/conversations", `{"purpose":"group"}`, "", 400},
		{"POST", "/api/v2/ai/conversations", `{"purpose":"knowledge","api_key":"no"}`, "", 400},
		{"POST", "/api/v2/ai/conversations/" + id + "/messages", `{"content":""}`, "", 400},
	}
	for _, tc := range cases {
		t.Run(tc.method+tc.path+tc.body, func(t *testing.T) {
			s := &aiHTTPFixture{memorySessions: store()}
			r := httptest.NewRequest(tc.method, tc.path, strings.NewReader(tc.body))
			r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			r.Header.Set("Content-Type", "application/json")
			w := httptest.NewRecorder()
			NewHandlerWithConfig(codec, s, CorsPolicy{}, RefreshConfig{}).ServeHTTP(w, r)
			if w.Code != tc.status || s.operation != tc.operation || w.Header().Get("Cache-Control") != "private, no-store" {
				t.Fatalf("status=%d operation=%s body=%s headers=%v", w.Code, s.operation, w.Body.String(), w.Header())
			}
			if tc.operation == "list" && (s.actor != 42 || s.after != 2 || s.limit != 10) {
				t.Fatal(s)
			}
		})
	}
	s := &aiHTTPFixture{memorySessions: store(), fail: errConversationForbidden}
	r := httptest.NewRequest("GET", "/api/v2/ai/conversations/"+id, nil)
	r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
	w := httptest.NewRecorder()
	NewHandler(codec, s, CorsPolicy{}).ServeHTTP(w, r)
	if w.Code != 403 || strings.Contains(w.Body.String(), "private") {
		t.Fatal(w.Code, w.Body.String())
	}
	s.fail = errors.New("private driver detail")
	w = httptest.NewRecorder()
	NewHandler(codec, s, CorsPolicy{}).ServeHTTP(w, r)
	if w.Code != 500 || strings.Contains(w.Body.String(), "private") {
		t.Fatal(w.Code, w.Body.String())
	}
	r = httptest.NewRequest("GET", "/api/v2/ai/conversations/"+id, nil)
	w = httptest.NewRecorder()
	NewHandler(codec, s, CorsPolicy{}).ServeHTTP(w, r)
	if w.Code != 401 || w.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatal(w.Code, w.Header())
	}
}

func TestAIConversationPolicyComesFromServerConfig(t *testing.T) {
	codec, tokens := fixture(t)
	s := &aiHTTPFixture{memorySessions: store()}
	r := httptest.NewRequest("POST", "/api/v2/ai/conversations", strings.NewReader(`{"purpose":"moderation"}`))
	r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
	w := httptest.NewRecorder()
	NewHandlerWithConfig(codec, s, CorsPolicy{}, RefreshConfig{ModerationAdminAccounts: "Alice", ModerationAllowAll: "false"}).ServeHTTP(w, r)
	if w.Code != 200 || s.policy.AllowAll || !s.policy.Accounts["alice"] || s.policy.Accounts["v2_admin"] {
		t.Fatal(w.Code, s.policy)
	}
}

func TestAIConversationModerationEnvironment(t *testing.T) {
	env := validEnv()
	env["MODERATION_ADMIN_ACCOUNTS"] = " Alice, staff@example.test "
	env["MODERATION_ALLOW_ALL"] = "false"
	config, err := LoadConfig(func(key string) (string, bool) { value, ok := env[key]; return value, ok })
	if err != nil {
		t.Fatal(err)
	}
	policy := conversationPolicy(config.Refresh.ModerationAllowAll, config.Refresh.ModerationAdminAccounts)
	if policy.AllowAll || !policy.Accounts["alice"] || !policy.Accounts["staff@example.test"] {
		t.Fatal(policy)
	}
}
