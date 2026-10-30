package server

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type knowledgeRouteFixture struct {
	*aiHTTPFixture
	rows      []knowledgeSource
	purpose   string
	failWrite error
	writes    int
}

func (f *knowledgeRouteFixture) readAIConversation(_ context.Context, _ int64, id string, _ moderationPolicy) (conversationRecord, error) {
	return conversationRecord{ID: id, Purpose: f.purpose}, nil
}
func (f *knowledgeRouteFixture) listAIRecentConversationMessages(_ context.Context, _ int64, id string, _ moderationPolicy) ([]conversationHistoryMessage, error) {
	return []conversationHistoryMessage{{ConversationID: id, SequenceNo: 1, Role: "user", Content: "猫"}}, nil
}
func (f *knowledgeRouteFixture) discoverKnowledgeSources(_ context.Context, _ int64, _ string, _ int) ([]knowledgeSource, error) {
	return f.rows, nil
}
func (f *knowledgeRouteFixture) hydrateKnowledgeSources(_ context.Context, _ int64, _ []knowledgeCandidate) ([]knowledgeSource, error) {
	return f.rows, nil
}
func (f *knowledgeRouteFixture) appendAIKnowledgeAssistantMessage(_ context.Context, _ int64, id string, input assistantMessageInput, refs []knowledgeCandidate, _ moderationPolicy) (conversationMessage, error) {
	f.writes++
	return conversationMessage{ID: "a", ConversationID: id, SequenceNo: 2, Role: "assistant"}, f.failWrite
}

func TestKnowledgeGenerationRoute(t *testing.T) {
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		if json.NewDecoder(r.Body).Decode(&body) != nil {
			t.Fatal("invalid provider request")
		}
		encoded, _ := json.Marshal(body)
		output := fakeKnowledgeAnswer(encoded)
		json.NewEncoder(w).Encode(map[string]any{"choices": []any{map[string]any{"index": 0, "finish_reason": "stop", "message": map[string]any{"role": "assistant", "content": output}}}})
	}))
	defer provider.Close()
	codec, tokens := fixture(t)
	id := "f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb"
	path := "/api/v2/ai/conversations/" + id + "/knowledge-generate"
	ref := knowledgeSource{Kind: "post", ID: 1, PostID: 1, Content: "资料", Version: strings.Repeat("a", 64)}
	for _, tc := range []struct {
		name    string
		rows    []knowledgeSource
		purpose string
		fail    error
		status  int
		body    string
		writes  int
	}{{"ok", []knowledgeSource{ref}, "knowledge", nil, 200, `"status":"generated"`, 1}, {"empty", nil, "knowledge", nil, 200, `"status":"insufficient_evidence"`, 0}, {"wrong", nil, "writing", nil, 400, "", 0}, {"conflict", []knowledgeSource{ref}, "knowledge", errConversationConflict, 409, "", 1}} {
		t.Run(tc.name, func(t *testing.T) {
			s := &knowledgeRouteFixture{aiHTTPFixture: &aiHTTPFixture{memorySessions: store()}, rows: tc.rows, purpose: tc.purpose, failWrite: tc.fail}
			req := httptest.NewRequest("POST", path, nil)
			req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			w := httptest.NewRecorder()
			NewHandlerWithConfig(codec, s, CorsPolicy{}, RefreshConfig{AIModelConfig: writingConfig(provider.URL)}).ServeHTTP(w, req)
			if w.Code != tc.status || !strings.Contains(w.Body.String(), tc.body) || w.Header().Get("Cache-Control") != "private, no-store" || s.writes != tc.writes {
				t.Fatal(w.Code, w.Body.String(), s.writes)
			}
		})
	}
	s := &knowledgeRouteFixture{aiHTTPFixture: &aiHTTPFixture{memorySessions: store()}}
	w := httptest.NewRecorder()
	NewHandler(codec, s, CorsPolicy{}).ServeHTTP(w, httptest.NewRequest("POST", path, nil))
	if w.Code != 401 || w.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatal(w.Code, w.Body.String())
	}
}
