package server

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type moderationFixtureStore struct {
	OracleSessions
	condition        string
	text             string
	images           []storedVisionImage
	vision           bool
	visionPreflights int
	written          *assistantMessageInput
}

func (s *moderationFixtureStore) Touch(_ context.Context, claims auth.Claims) (int64, error) {
	if claims.UserID == 42 {
		return 1, nil
	}
	return 0, nil
}
func (s *moderationFixtureStore) loadModerationAdvice(_ context.Context, _ int64, _ string, request moderationAdviceRequest, _ moderationPolicy) (*moderationMaterial, int64, error) {
	s.vision = request.Vision
	switch s.condition {
	case "wrong_purpose":
		return nil, 0, errConversationInvalid
	case "forbidden":
		return nil, 0, errConversationForbidden
	case "disabled":
		return nil, 0, errSkillUnavailable
	case "terms_unavailable":
		return nil, 0, errTermsAuthorityUnavailable
	case "empty":
		return nil, 4, nil
	default:
		target := moderationTargetReference{Kind: request.Kind, ID: request.ID, PostID: request.ID}
		target.Digest = targetDigest(target, s.text)
		return &moderationMaterial{Target: target, Content: s.text, Authority: termsAuthority{Digest: strings.Repeat("a", 64), Generation: 9},
			Rules: []moderationRule{{ID: 3, Version: strings.Repeat("b", 64), Title: "Conduct", Blocks: []string{"Rule text"}}}, Images: s.images}, 4, nil
	}
}
func (s *moderationFixtureStore) appendAIAssistantMessage(_ context.Context, _ int64, id string, in assistantMessageInput, _ moderationPolicy) (conversationMessage, error) {
	if s.condition == "changed" {
		return conversationMessage{}, errConversationConflict
	}
	s.written = &in
	return conversationMessage{ID: "review", ConversationID: id, SequenceNo: 1, Role: "assistant"}, nil
}

func (s *moderationFixtureStore) verifyModerationVisionInputs(_ context.Context, actor int64, record *moderationAdviceRecord) error {
	s.visionPreflights++
	if s.condition == "image_changed" || actor != 42 || record.Version != 2 || !validModerationImageReferences(record.ImageSources) {
		return errConversationConflict
	}
	return nil
}

func TestModerationAdviceSharedScenarios(t *testing.T) {
	var spec struct {
		Text       string
		GoodAdvice moderationOpinion
		Cases      []struct {
			ID, Condition, Body, Status string
			HTTP                        int
		}
	}
	raw, err := os.ReadFile("../../contracts/scenarios/ai-moderation-advice-http.json")
	if err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal(raw, &spec); err != nil {
		t.Fatal(err)
	}
	codec, tokens := fixture(t)
	for _, entry := range spec.Cases {
		t.Run(entry.ID, func(t *testing.T) {
			var calls atomic.Int64
			provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				var sent map[string]interface{}
				if json.NewDecoder(r.Body).Decode(&sent) != nil || sent["response_format"] == nil || sent["model"] != "test-model" {
					t.Error("missing structured moderation model request")
				}
				advice := spec.GoodAdvice
				if entry.Condition == "fabricated_rule" {
					advice.RuleIDs = []int64{999}
				}
				if entry.Condition == "wrong_locale" {
					advice.RuleIDs = []int64{7}
				}
				encoded, _ := json.Marshal(advice)
				if entry.Condition == "tool_proposal" {
					fmt.Fprint(w, `{"choices":[{"index":0,"finish_reason":"tool_calls","message":{"role":"assistant","tool_calls":[{"id":"x","type":"function","function":{"name":"delete","arguments":"{}"}}]}}]}`)
					return
				}
				fmt.Fprintf(w, `{"choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":%q}}]}`, encoded)
			}))
			defer provider.Close()
			config := RefreshConfig{AIModelQuotaLimiter: singleCallAIQuota{}, AIModelConfig: fmt.Sprintf(`{"schemaVersion":1,"revision":7,"providers":[{"id":"local","adapter":"openai-compatible","baseUrl":%q}],"models":[{"id":"reviewer","providerId":"local","model":"test-model","capabilities":["tools","structured-output"],"contextWindowTokens":8192,"maxOutputTokens":512}],"bindings":{"knowledge":"reviewer","writing":"reviewer","agent":"reviewer","moderation":"reviewer"}}`, provider.URL)}
			store := &moderationFixtureStore{condition: entry.Condition, text: spec.Text}
			request := httptest.NewRequest(http.MethodPost, "/api/v2/ai/conversations/e7dd4d7f-8462-45b6-9bf4-a630d0ba7478/moderation-generate", strings.NewReader(entry.Body))
			if entry.Condition != "anonymous" {
				request.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			}
			response := httptest.NewRecorder()
			if !aiConversationRoute(response, request, codec, store, config) || response.Code != entry.HTTP {
				t.Fatalf("expected %d; got %d %s", entry.HTTP, response.Code, response.Body.String())
			}
			if response.Header().Get("Cache-Control") != "private, no-store" {
				t.Fatal("cache policy")
			}
			if entry.Status != "" {
				var body struct{ Data struct{ Status string } }
				if json.Unmarshal(response.Body.Bytes(), &body) != nil || body.Data.Status != entry.Status {
					t.Fatal(response.Body.String())
				}
			}
			if entry.Status == "generated" {
				if store.written == nil || store.written.ModerationAdvice == nil ||
					store.written.ModerationAdvice.TermsGeneration != 9 || store.written.SkillGeneration != 4 ||
					store.written.ModerationAdvice.Advice.Risk != spec.GoodAdvice.Risk {
					t.Fatal("incorrect advice write")
				}
			} else if store.written != nil {
				t.Fatal("unexpected assistant write")
			}
			switch entry.Condition {
			case "anonymous", "forbidden", "invalid", "wrong_purpose", "disabled", "terms_unavailable", "empty":
				if calls.Load() != 0 {
					t.Fatal("denied or empty request reached the model")
				}
			}
		})
	}
}
