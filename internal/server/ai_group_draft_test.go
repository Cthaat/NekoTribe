package server

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"slices"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/Cthaat/NekoTribe/backend-go/internal/ai"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type groupDraftFixtureStore struct {
	OracleSessions
	condition string
	evidence  groupEvidence
	written   *assistantMessageInput
	loads     int
}

type groupDraftFixtureQuota struct {
	condition string
	retry     int64
	calls     int
}

func (q *groupDraftFixtureQuota) ReserveAIModelQuota(_ context.Context, actor, cost int64) (int64, error) {
	q.calls++
	if actor != 42 || cost != 2 || q.condition == "quota_unavailable" {
		return 0, errAIQuotaUnavailable
	}
	return q.retry, nil
}

func (s *groupDraftFixtureStore) Touch(_ context.Context, actor auth.Claims) (int64, error) {
	if actor.UserID != 42 {
		return 0, nil
	}
	return 1, nil
}
func (s *groupDraftFixtureStore) loadGroupDraft(_ context.Context, _ int64, _ string, request groupDraftRequest, _ moderationPolicy) (groupEvidence, int64, error) {
	s.loads++
	if (s.condition == "admin_search" || (s.condition == "focused_search" && s.loads == 2)) &&
		(request.searchTerm == nil || *request.searchTerm != "活动报名") {
		return groupEvidence{}, 0, errConversationInvalid
	}
	if s.loads == 2 {
		switch s.condition {
		case "revoked_after_proposal":
			return groupEvidence{}, 0, errConversationForbidden
		case "skill_changed":
			return s.evidence, 7, nil
		case "evidence_gone":
			return groupEvidence{}, 6, nil
		}
	}
	switch s.condition {
	case "wrong_purpose":
		return groupEvidence{}, 0, errConversationInvalid
	case "forbidden":
		return groupEvidence{}, 0, errConversationForbidden
	case "skill_unavailable", "missing_tool_grant":
		return groupEvidence{}, 0, errSkillUnavailable
	case "empty":
		return groupEvidence{}, 6, nil
	default:
		return s.evidence, 6, nil
	}
}
func (s *groupDraftFixtureStore) appendAIAssistantMessage(_ context.Context, _ int64, id string, in assistantMessageInput, _ moderationPolicy) (conversationMessage, error) {
	if s.condition == "changed" {
		return conversationMessage{}, errConversationConflict
	}
	s.written = &in
	if (s.condition == "focused_search" || s.condition == "admin_search") &&
		(in.GroupDraft == nil || in.GroupDraft.SearchTerm == nil || *in.GroupDraft.SearchTerm != "活动报名" || !in.GroupDraft.MatchExcerpt) {
		return conversationMessage{}, errConversationInvalid
	}
	return conversationMessage{ID: "draft", ConversationID: id, SequenceNo: 1, Role: "assistant"}, nil
}

func TestGroupDraftRouteSharedScenarios(t *testing.T) {
	var spec struct {
		Evidence     groupEvidence
		Digest       string
		DefaultTools []ai.ToolProposal
		Bulk         struct {
			SampleCount, Context, SampleUsed int
			Digest, Excerpt                  string
		}
		Cases []struct {
			ID, Body, Status, Condition string
			HTTP, Loads, Inferences     int
			Tools                       []ai.ToolProposal
			Reservations                int
			RetryAfter                  int64
		}
	}
	raw, err := os.ReadFile("../../contracts/scenarios/ai-group-draft.json")
	if err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal(raw, &spec); err != nil {
		t.Fatal(err)
	}
	codec, tokens := fixture(t)
	for _, entry := range spec.Cases {
		t.Run(entry.ID, func(t *testing.T) {
			evidence, digest, usedExamples := spec.Evidence, spec.Digest, len(spec.Evidence.Examples)
			if entry.Condition == "trimmed" {
				evidence.PostsCount = int64(spec.Bulk.SampleCount)
				evidence.Examples = make([]groupEvidenceExample, spec.Bulk.SampleCount)
				for i := range evidence.Examples {
					id := int64(10 + i)
					evidence.Examples[i] = groupEvidenceExample{Kind: "post", SourceID: id, PostID: id, Excerpt: spec.Bulk.Excerpt}
				}
				digest, usedExamples = spec.Bulk.Digest, spec.Bulk.SampleUsed
			}
			proposals := entry.Tools
			if proposals == nil {
				proposals = spec.DefaultTools
			}
			var inferences atomic.Int32
			provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/chat/completions" {
					t.Errorf("model endpoint %s", r.URL.Path)
				}
				callNumber := inferences.Add(1)
				var request struct {
					Tools    []json.RawMessage
					Messages []struct {
						Role, Content string
						ToolCallID    string `json:"tool_call_id"`
					}
				}
				if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
					t.Error(err)
					w.WriteHeader(400)
					return
				}
				if callNumber == 1 {
					var job map[string]string
					expected, _ := parseGroupDraftRequest([]byte(entry.Body))
					wantFields, wantTerm := 1, ""
					if expected.searchTerm != nil {
						wantFields, wantTerm = 2, *expected.searchTerm
					}
					if len(request.Tools) != 2 || len(request.Messages) != 2 ||
						json.Unmarshal([]byte(request.Messages[1].Content), &job) != nil ||
						len(job) != wantFields || job["kind"] != expected.Kind || job["search_term"] != wantTerm {
						t.Errorf("unexpected first request: %+v", request)
					}
				} else if len(request.Tools) != 0 || len(request.Messages) != 3+len(proposals) {
					t.Errorf("unexpected followup: %+v", request)
				} else {
					for i, call := range proposals {
						tool := request.Messages[3+i]
						var output map[string]json.RawMessage
						if tool.Role != "tool" || tool.ToolCallID != call.ID ||
							json.Unmarshal([]byte(tool.Content), &output) != nil {
							t.Error("unmatched tool result")
							continue
						}
						if call.Name == "public_search" {
							var examples groupEvidence
							if json.Unmarshal(output["examples"], &examples.Examples) != nil ||
								!slices.Equal(examples.Examples, evidence.Examples[:usedExamples]) || len(output) != 3 {
								t.Error("wrong excerpts")
							}
						} else if string(output["posts_count"]) != fmt.Sprint(evidence.PostsCount) ||
							string(output["comments_count"]) != fmt.Sprint(evidence.CommentsCount) || len(output) != 4 {
							t.Error("wrong statistics")
						}
					}
				}
				if (callNumber != 1 && entry.Condition != "continued_tool") || len(proposals) == 0 {
					fmt.Fprint(w, `{"choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"人工审阅草稿"}}]}`)
					return
				}
				var wireCalls []map[string]any
				for _, proposal := range proposals {
					args, _ := json.Marshal(proposal.Arguments)
					wireCalls = append(wireCalls, map[string]any{"id": proposal.ID, "type": "function",
						"function": map[string]string{"name": proposal.Name, "arguments": string(args)}})
				}
				err := json.NewEncoder(w).Encode(map[string]any{"choices": []map[string]any{{
					"index": 0, "finish_reason": "tool_calls",
					"message": map[string]any{"role": "assistant", "content": nil, "tool_calls": wireCalls},
				}}})
				if err != nil {
					t.Error(err)
				}
			}))
			defer provider.Close()
			config := RefreshConfig{AIModelConfig: fmt.Sprintf(`{"schemaVersion":1,"revision":7,"providers":[{"id":"local","adapter":"openai-compatible","baseUrl":%q}],"models":[{"id":"writer","providerId":"local","model":"test-model","capabilities":["tools","structured-output"],"contextWindowTokens":8192,"maxOutputTokens":512}],"bindings":{"knowledge":"writer","writing":"writer","agent":"writer","moderation":"writer"}}`, provider.URL)}
			quota := &groupDraftFixtureQuota{condition: entry.Condition, retry: entry.RetryAfter}
			config.AIModelQuotaLimiter = quota
			if entry.Condition == "tools_unsupported" {
				config.AIModelConfig = strings.Replace(config.AIModelConfig, `"tools",`, "", 1)
			}
			if entry.Condition == "low_budget" {
				config.AIModelConfig = strings.Replace(config.AIModelConfig, `"contextWindowTokens":8192`, `"contextWindowTokens":700`, 1)
			}
			if entry.Condition == "trimmed" {
				config.AIModelConfig = strings.Replace(config.AIModelConfig, `"contextWindowTokens":8192`, fmt.Sprintf(`"contextWindowTokens":%d`, spec.Bulk.Context), 1)
			}
			store := &groupDraftFixtureStore{condition: entry.Condition, evidence: evidence}
			req := httptest.NewRequest(http.MethodPost, "/api/v2/ai/conversations/e7dd4d7f-8462-45b6-9bf4-a630d0ba7478/group-generate", strings.NewReader(entry.Body))
			if entry.Condition != "anonymous" {
				req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			}
			response := httptest.NewRecorder()
			if !aiConversationRoute(response, req, codec, store, config) || response.Code != entry.HTTP {
				t.Fatalf("response %d %s", response.Code, response.Body.String())
			}
			if response.Header().Get("Cache-Control") != "private, no-store" {
				t.Fatal("cache policy")
			}
			expectedRetry := ""
			if entry.RetryAfter > 0 {
				expectedRetry = fmt.Sprint(entry.RetryAfter)
			}
			if quota.calls != entry.Reservations || response.Header().Get("Retry-After") != expectedRetry {
				t.Fatalf("unexpected quota result: %d, %q", quota.calls, response.Header().Get("Retry-After"))
			}
			if store.loads != entry.Loads || int(inferences.Load()) != entry.Inferences {
				t.Fatalf("unexpected reads and inferences: %d %d", store.loads, inferences.Load())
			}
			if entry.Status != "" {
				var body struct{ Data struct{ Status string } }
				if json.Unmarshal(response.Body.Bytes(), &body) != nil || body.Data.Status != entry.Status {
					t.Fatal(response.Body.String())
				}
			}
			if entry.Status == "generated" {
				var used []string
				for _, proposal := range proposals {
					used = append(used, proposal.Name)
				}
				if store.written == nil || store.written.GroupDraft == nil || store.written.GroupDraft.SourceDigest != digest ||
					store.written.GroupDraft.ExampleCount != usedExamples ||
					store.written.ExpectedSequence != 0 || store.written.SkillGeneration != 6 || !slices.Equal(store.written.GroupDraft.ToolsUsed, used) {
					t.Fatal("incorrect durable assistant write", store.written)
				}
			} else if store.written != nil {
				t.Fatal("unexpected assistant write")
			}
		})
	}
}
