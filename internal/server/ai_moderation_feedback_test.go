package server

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

type feedbackFixtureStore struct {
	moderationFixtureStore
	id, messageID string
	calls         int
}

func (s *feedbackFixtureStore) saveModerationFeedback(_ context.Context, actor int64, id, messageID, rating string, _ moderationPolicy) (moderationFeedbackReceipt, error) {
	s.calls++
	if actor != 42 || id != s.id || messageID != s.messageID {
		return moderationFeedbackReceipt{}, errConversationInvalid
	}
	switch s.condition {
	case "forbidden":
		return moderationFeedbackReceipt{}, errConversationForbidden
	case "not_owner", "not_message":
		return moderationFeedbackReceipt{}, errConversationNotFound
	case "redacted", "changed":
		return moderationFeedbackReceipt{}, errConversationConflict
	case "old_schema":
		return moderationFeedbackReceipt{}, errConversationSchema
	default:
		return moderationFeedbackReceipt{MessageID: messageID, Rating: rating}, nil
	}
}

func TestModerationFeedbackSharedScenarios(t *testing.T) {
	var spec struct {
		ConversationID, MessageID string
		Cases                     []struct {
			ID, Condition, Body, Rating string
			HTTP                        int
		}
	}
	raw, err := os.ReadFile("../../contracts/scenarios/ai-moderation-feedback-http.json")
	if err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal(raw, &spec); err != nil {
		t.Fatal(err)
	}
	codec, tokens := fixture(t)
	for _, entry := range spec.Cases {
		t.Run(entry.ID, func(t *testing.T) {
			store := &feedbackFixtureStore{
				moderationFixtureStore: moderationFixtureStore{condition: entry.Condition},
				id:                     spec.ConversationID, messageID: spec.MessageID,
			}
			message := spec.MessageID
			if entry.Condition == "invalid_id" {
				message = "invalid"
			}
			path := "/api/v2/ai/conversations/" + spec.ConversationID + "/messages/" + message + "/moderation-feedback"
			req := httptest.NewRequest(http.MethodPut, path, strings.NewReader(entry.Body))
			if entry.Condition != "anonymous" {
				req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			}
			res := httptest.NewRecorder()
			if !aiConversationRoute(res, req, codec, store, RefreshConfig{}) || res.Code != entry.HTTP {
				t.Fatalf("expected %d, got %d: %s", entry.HTTP, res.Code, res.Body.String())
			}
			if res.Header().Get("Cache-Control") != "private, no-store" {
				t.Fatal("cache policy")
			}
			if entry.HTTP == 200 {
				var envelope struct{ Data moderationFeedbackReceipt }
				if json.Unmarshal(res.Body.Bytes(), &envelope) != nil ||
					envelope.Data != (moderationFeedbackReceipt{MessageID: spec.MessageID, Rating: entry.Rating}) {
					t.Fatal(res.Body.String())
				}
			}
			if entry.Condition == "anonymous" || entry.Condition == "invalid_id" || entry.Condition == "invalid" {
				if store.calls != 0 {
					t.Fatal("store called before validation")
				}
			} else if store.calls != 1 {
				t.Fatal("expected exactly one store call")
			}
		})
	}
}
