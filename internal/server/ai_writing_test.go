package server

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type writingFixture struct {
	*aiHTTPFixture
	events    []string
	latest    int64
	purpose   string
	failWrite error
}

func (s *writingFixture) readAIConversation(_ context.Context, _ int64, id string, _ moderationPolicy) (conversationRecord, error) {
	s.events = append(s.events, "read")
	return conversationRecord{ID: id, Purpose: s.purpose}, nil
}
func (s *writingFixture) listAIRecentConversationMessages(_ context.Context, _ int64, id string, _ moderationPolicy) ([]conversationHistoryMessage, error) {
	s.events = append(s.events, "load")
	return []conversationHistoryMessage{{ConversationID: id, SequenceNo: s.latest, Role: "user", Content: "润色这段文字"}}, nil
}
func (s *writingFixture) appendAIAssistantMessage(_ context.Context, _ int64, id string, input assistantMessageInput, _ moderationPolicy) (conversationMessage, error) {
	s.events = append(s.events, "write")
	if input.ExpectedSequence != s.latest || input.ModelID != "writer" || input.ConfigRevision != 1 || input.Content != "草稿" {
		return conversationMessage{}, fmt.Errorf("wrong input")
	}
	return conversationMessage{ID: "result", ConversationID: id, SequenceNo: s.latest + 1, Role: "assistant"}, s.failWrite
}
func writingConfig(base string) string {
	return fmt.Sprintf(`{"schemaVersion":1,"revision":1,"providers":[{"id":"local","adapter":"openai-compatible","baseUrl":%q}],"models":[{"id":"writer","providerId":"local","model":"test-model","capabilities":["tools","structured-output"],"contextWindowTokens":4096,"maxOutputTokens":512}],"bindings":{"knowledge":"writer","writing":"writer","agent":"writer","moderation":"writer"}}`, base)
}

func TestWritingGenerationRouteCallsModelAndSavesVersion(t *testing.T) {
	var calls int
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		var body map[string]any
		if json.NewDecoder(r.Body).Decode(&body) != nil || body["model"] != "test-model" {
			t.Error("bad provider request")
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"草稿"}}]}`)
	}))
	defer provider.Close()
	codec, tokens := fixture(t)
	s := &writingFixture{aiHTTPFixture: &aiHTTPFixture{memorySessions: store()}, latest: 4, purpose: "writing"}
	request := httptest.NewRequest("POST", "/api/v2/ai/conversations/f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb/generate", nil)
	request.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
	recorder := httptest.NewRecorder()
	NewHandlerWithConfig(codec, s, CorsPolicy{}, RefreshConfig{AIModelConfig: writingConfig(provider.URL)}).ServeHTTP(recorder, request)
	if recorder.Code != 200 || calls != 1 || strings.Join(s.events, ",") != "read,load,write" || recorder.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatal(recorder.Code, recorder.Body.String(), calls, s.events)
	}
}
func TestWritingGenerationRejectsNonWritingAndStaleResult(t *testing.T) {
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"草稿"}}]}`)
	}))
	defer provider.Close()
	codec, tokens := fixture(t)
	for _, tc := range []struct {
		purpose string
		fail    error
		status  int
	}{{"knowledge", nil, 400}, {"writing", errConversationConflict, 409}} {
		s := &writingFixture{aiHTTPFixture: &aiHTTPFixture{memorySessions: store()}, latest: 4, purpose: tc.purpose, failWrite: tc.fail}
		request := httptest.NewRequest("POST", "/api/v2/ai/conversations/f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb/generate", nil)
		request.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		w := httptest.NewRecorder()
		NewHandlerWithConfig(codec, s, CorsPolicy{}, RefreshConfig{AIModelConfig: writingConfig(provider.URL)}).ServeHTTP(w, request)
		if w.Code != tc.status {
			t.Fatal(w.Code, w.Body.String(), s.events)
		}
	}
}

func TestWritingGenerationFailureAndCancellationNeverWrite(t *testing.T) {
	calls := 0
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls++; w.WriteHeader(500) }))
	defer provider.Close()
	s := &writingFixture{aiHTTPFixture: &aiHTTPFixture{memorySessions: store()}, latest: 4, purpose: "writing"}
	_, err := generateAIWriting(context.Background(), s, 42, "id", conversationPolicy("", ""), RefreshConfig{AIModelConfig: writingConfig(provider.URL)})
	if err != errWritingUnavailable || calls != 1 || strings.Join(s.events, ",") != "read,load" {
		t.Fatal(err, calls, s.events)
	}
	s.events = nil
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err = generateAIWriting(ctx, s, 42, "id", conversationPolicy("", ""), RefreshConfig{AIModelConfig: writingConfig(provider.URL)})
	if err != errWritingUnavailable || len(s.events) != 0 || calls != 1 {
		t.Fatal(err, calls, s.events)
	}
}
