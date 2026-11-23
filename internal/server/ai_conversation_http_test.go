package server

import (
	"context"
	"errors"
	"io"
	"net/http/httptest"
	"strings"
	"testing"
)

type aiHTTPFixture struct {
	*memorySessions
	operation            string
	actor                int64
	after, before, limit int64
	content              string
	cursor               string
	purpose              string
	scope                knowledgeScope
	groupID              *int64
	targetTitle          string
	policy               moderationPolicy
	fail                 error
}

func (s *aiHTTPFixture) listAIConversations(_ context.Context, user int64, after string, limit int, purpose string, groupID *int64, targetTitle string, scope knowledgeScope, policy moderationPolicy) (conversationPage, error) {
	s.operation = "list-owned"
	s.actor = user
	s.cursor = after
	s.limit = int64(limit)
	s.purpose = purpose
	s.scope = scope
	s.groupID = groupID
	s.targetTitle = targetTitle
	return conversationPage{Items: []conversationRecord{}}, s.fail
}

func (s *aiHTTPFixture) createAIConversation(_ context.Context, user int64, input conversationInput, policy moderationPolicy) (conversationRecord, error) {
	s.operation = "create"
	s.actor = user
	s.policy = policy
	return conversationRecord{ID: "f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb", Purpose: input.Purpose, GroupID: input.GroupID, KnowledgeScope: input.KnowledgeScope}, s.fail
}
func (s *aiHTTPFixture) readAIConversation(_ context.Context, user int64, id string, policy moderationPolicy) (conversationRecord, error) {
	s.operation = "read"
	s.actor = user
	return conversationRecord{ID: id, Purpose: "knowledge"}, s.fail
}
func (s *aiHTTPFixture) deleteAIConversation(_ context.Context, user int64, id string, policy moderationPolicy) error {
	s.operation = "delete"
	s.actor = user
	return s.fail
}
func (s *aiHTTPFixture) appendAIUserMessage(_ context.Context, user int64, id, content string, policy moderationPolicy) (conversationMessage, error) {
	s.operation = "append"
	s.actor = user
	s.content = content
	return conversationMessage{ID: id, ConversationID: id, SequenceNo: 1, Role: "user"}, s.fail
}
func (s *aiHTTPFixture) listAIConversationMessages(_ context.Context, user int64, id string, after, before, limit int64, policy moderationPolicy) ([]conversationHistoryMessage, error) {
	s.operation = "list"
	s.actor = user
	s.after = after
	s.before = before
	s.limit = limit
	return []conversationHistoryMessage{}, s.fail
}
func TestAIConversationHTTPBody(t *testing.T) {
	codec, tokens := fixture(t)
	for _, route := range []struct{ path, json, form, duplicate, operation string }{
		{"/api/v2/ai/conversations", `{"purpose":"writing"}`, "purpose=writing", `{"purpose":"knowledge","purpo\u0073e":"writing"}`, "create"},
		{"/api/v2/ai/conversations/f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb/messages", `{"content":"猫😺"}`, "content=hello", `{"content":"first","cont\u0065nt":"replacement"}`, "append"},
	} {
		padded := route.json + strings.Repeat(" ", (1<<20)-len(route.json))
		for _, tc := range []struct {
			name, body, mediaType string
			status                int
		}{
			{"limit", padded, "application/json", 200},
			{"over limit", padded + " ", "application/json", 400},
			{"form", route.form, "application/x-www-form-urlencoded", 400},
			{"array", "[]", "application/json", 400},
			{"extra object", route.json + "{}", "application/json", 400},
			{"duplicate member", route.duplicate, "application/json", 400},
			{"invalid UTF-8", "{\"content\":\"\xff\"}", "application/json", 400},
			{"unpaired surrogate", `{"content":"\ud800"}`, "application/json", 400},
		} {
			t.Run(route.operation+"/"+tc.name, func(t *testing.T) {
				s := &aiHTTPFixture{memorySessions: store()}
				r := httptest.NewRequest("POST", route.path, io.NopCloser(strings.NewReader(tc.body)))
				r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
				r.Header.Set("Content-Type", tc.mediaType)
				w := httptest.NewRecorder()
				NewHandlerWithConfig(codec, s, CorsPolicy{}, RefreshConfig{}).ServeHTTP(w, r)
				wantOperation := ""
				if tc.status == 200 {
					wantOperation = route.operation
				}
				if w.Code != tc.status || s.operation != wantOperation {
					t.Fatalf("status=%d operation=%s body=%s", w.Code, s.operation, w.Body.String())
				}
			})
		}
	}
}

func TestAIConversationHTTPRoutes(t *testing.T) {
	codec, tokens := fixture(t)
	id := "f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb"
	cases := []struct {
		method, path, body, operation string
		status                        int
	}{
		{"POST", "/api/v2/ai/conversations", `{"purpose":"knowledge"}`, "create", 200},
		{"GET", "/api/v2/ai/conversations?limit=10", "", "list-owned", 200},
		{"GET", "/api/v2/ai/conversations?purpose=knowledge", "", "list-owned", 200},
		{"GET", "/api/v2/ai/conversations?purpose=group&group_id=7", "", "list-owned", 200},
		{"GET", "/api/v2/ai/conversations?purpose=moderation&target_type=post&target_id=17", "", "list-owned", 200},
		{"GET", "/api/v2/ai/conversations?purpose=moderation&target_type=post", "", "", 400},
		{"GET", "/api/v2/ai/conversations?purpose=moderation&target_type=user&target_id=17", "", "", 400},
		{"GET", "/api/v2/ai/conversations?purpose=writing&group_id=7", "", "", 400},
		{"GET", "/api/v2/ai/conversations?purpose=group&group_id=7&group_id=8", "", "", 400},
		{"GET", "/api/v2/ai/conversations?purpose=", "", "", 400},
		{"GET", "/api/v2/ai/conversations?purpose=knowledge&purpose=writing", "", "", 400},
		{"GET", "/api/v2/ai/conversations?after_id=bad", "", "", 400},
		{"GET", "/api/v2/ai/conversations?limit=1&limit=2", "", "", 400},
		{"GET", "/api/v2/ai/conversations/" + id, "", "read", 200},
		{"DELETE", "/api/v2/ai/conversations/" + id, "", "delete", 200},
		{"POST", "/api/v2/ai/conversations/" + id + "/messages", `{"content":"你好"}`, "append", 200},
		{"GET", "/api/v2/ai/conversations/" + id + "/messages?after_sequence=2&limit=10", "", "list", 200},
		{"GET", "/api/v2/ai/conversations/" + id + "/messages?before_sequence=10000000000&limit=10", "", "list", 200},
		{"GET", "/api/v2/ai/conversations/" + id + "/messages?before_sequence=0", "", "", 400},
		{"GET", "/api/v2/ai/conversations/" + id + "/messages?before_sequence=2&after_sequence=0", "", "", 400},
		{"GET", "/api/v2/ai/conversations/" + id + "/messages?before_sequence=2&before_sequence=3", "", "", 400},
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
			if tc.operation == "delete" && (s.actor != 42 || !strings.Contains(w.Body.String(), `"data":null`)) {
				t.Fatal(s.actor, w.Body.String())
			}
			if tc.operation == "list" {
				after, before := int64(2), int64(0)
				if r.URL.Query().Has("before_sequence") {
					after, before = 0, 10000000000
				}
				if s.actor != 42 || s.after != after || s.before != before || s.limit != 10 {
					t.Fatal(s)
				}
			}
			if strings.HasSuffix(tc.path, "?purpose=knowledge") && s.purpose != "knowledge" {
				t.Fatal(s.purpose)
			}
			if strings.HasSuffix(tc.path, "?purpose=group&group_id=7") && (s.groupID == nil || *s.groupID != 7) {
				t.Fatal(s.groupID)
			}
			if tc.operation == "list-owned" && strings.Contains(tc.path, "target_id=") && s.targetTitle != "moderation:post:17" {
				t.Fatal(s.targetTitle)
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
	r = httptest.NewRequest("DELETE", "/api/v2/ai/conversations/"+id, nil)
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
