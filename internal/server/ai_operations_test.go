package server

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type opsFixture struct {
	*memorySessions
	allowed bool
}

func (s *opsFixture) ModerationAllowed(_ context.Context, actor int64, _ moderationPolicy) (bool, error) {
	return actor == 42 && s.allowed, nil
}

func (*opsFixture) ReadAIOps(context.Context, int64) ([]aiOpsFeedback, *aiOpsSkills, error) {
	accuracy := 0.75
	return []aiOpsFeedback{{Helpful: 3, Incorrect: 1, Insufficient: 2, Accuracy: &accuracy}}, nil, nil
}

func TestAIOperationsOverview(t *testing.T) {
	t.Setenv("AI_KNOWLEDGE_INDEX_URL", "")
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/models" {
			t.Errorf("unexpected health path %s", r.URL.Path)
		}
		_, _ = w.Write([]byte(`{"data":[{"id":"test-model"}]}`))
	}))
	defer provider.Close()
	codec, tokens := fixture(t)
	repository := &opsFixture{memorySessions: store(), allowed: true}
	handler := NewHandlerWithConfig(codec, repository, CorsPolicy{}, RefreshConfig{AIModelConfig: writingConfig(provider.URL)})
	request := func(authenticated bool) *httptest.ResponseRecorder {
		req := httptest.NewRequest("GET", "/api/v2/moderation/ai/operations", nil)
		if authenticated {
			req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		}
		res := httptest.NewRecorder()
		handler.ServeHTTP(res, req)
		return res
	}
	res := request(true)
	var payload struct {
		Data struct {
			Models   []aiOpsModel
			Feedback []aiOpsFeedback
			Index    *aiOpsIndex
		}
	}
	if res.Code != 200 || json.Unmarshal(res.Body.Bytes(), &payload) != nil ||
		len(payload.Data.Models) != 4 || payload.Data.Models[0].State != "ready" ||
		len(payload.Data.Feedback) != 1 || payload.Data.Feedback[0].Incorrect != 1 ||
		payload.Data.Index != nil || strings.Contains(res.Body.String(), provider.URL) {
		t.Fatal(res.Code, res.Body.String())
	}
	repository.allowed = false
	if res := request(true); res.Code != 403 {
		t.Fatal(res.Code, res.Body.String())
	}
	if res := request(false); res.Code != 401 {
		t.Fatal(res.Code, res.Body.String())
	}
}
