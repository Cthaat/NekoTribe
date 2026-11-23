package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
)

type sentimentDraftFixture struct {
	*groupDraftFixtureStore
	previous groupEvidence
	reads    int
}

func (s *sentimentDraftFixture) loadGroupSentimentWindow(_ context.Context, actor int64, _ string, query groupEvidenceQuery, _ moderationPolicy) (groupEvidence, error) {
	s.reads++
	if actor != 42 || query.LookbackDays != 7 || query.SearchTerm == nil || *query.SearchTerm != "topic" || !query.MatchExcerpt || query.WindowEnd == nil || *query.WindowEnd != s.previous.WindowEnd {
		return groupEvidence{}, errConversationInvalid
	}
	return s.previous, nil
}

func sentimentDraftEvidence(start, end, label string) groupEvidence {
	evidence := groupEvidence{WindowStart: start, WindowEnd: end, PostsCount: 5}
	for i := int64(1); i <= 5; i++ {
		evidence.Examples = append(evidence.Examples, groupEvidenceExample{Kind: "post", SourceID: i, PostID: i, Excerpt: fmt.Sprint(label, i)})
	}
	return evidence
}

func TestSentimentGroupDraftOptionalTool(t *testing.T) {
	current := sentimentDraftEvidence("2026-11-10T12:00:00.000000", "2026-11-17T12:00:00.000000", "current")
	previous := sentimentDraftEvidence("2026-11-03T12:00:00.000000", current.WindowStart, "previous")
	for _, available := range []bool{true, false} {
		t.Run(fmt.Sprint("available=", available), func(t *testing.T) {
			client := configuredSentimentForTest(t)
			var predictions atomic.Int32
			client.http.Transport = knowledgeIndexTransportFunc(func(request *http.Request) (*http.Response, error) {
				predictions.Add(1)
				var input struct{ Text string }
				if json.NewDecoder(request.Body).Decode(&input) != nil || strings.HasSuffix(input.Text, "5") {
					t.Error("only the four newest samples of each window should be submitted")
				}
				if !available {
					return &http.Response{StatusCode: 503, Body: io.NopCloser(strings.NewReader(""))}, nil
				}
				label := "positive"
				if strings.HasPrefix(input.Text, "current") {
					label = "negative"
				}
				body := fmt.Sprintf(`{"data":{"prediction":{"label":%q,"confidence":0.8}}}`, label)
				return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body))}, nil
			})
			var inferences atomic.Int32
			provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var request struct {
					Tools    []struct{ Function groupDraftTool }
					Messages []struct{ Role, Content string }
				}
				if json.NewDecoder(r.Body).Decode(&request) != nil {
					w.WriteHeader(400)
					return
				}
				if inferences.Add(1) == 1 {
					if len(request.Tools) != 3 || request.Tools[2].Function.Name != sentimentContract.Tool.Name {
						t.Error("missing optional tool")
					}
					fmt.Fprint(w, `{"choices":[{"index":0,"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[{"id":"search","type":"function","function":{"name":"public_search","arguments":"{}"}},{"id":"trend","type":"function","function":{"name":"community_sentiment_summary","arguments":"{}"}}]}}]}`)
					return
				}
				if len(request.Messages) != 5 || request.Messages[4].Role != "tool" {
					t.Error("missing trend tool result")
					w.WriteHeader(400)
					return
				}
				if available {
					var report groupSentimentReport
					if json.Unmarshal([]byte(request.Messages[4].Content), &report) != nil || report.Status != "available" || report.Current.Negative != 4 || report.Previous.Positive != 4 || report.NegativeShareChange == nil || *report.NegativeShareChange != 1 {
						t.Error("incorrect sample trend", report)
					}
				} else if request.Messages[4].Content != `{"status":"unavailable"}` {
					t.Error("plugin failure should produce an unavailable tool result")
				}
				fmt.Fprint(w, `{"choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"Draft"}}]}`)
			}))
			defer provider.Close()
			store := &sentimentDraftFixture{groupDraftFixtureStore: &groupDraftFixtureStore{evidence: current}, previous: previous}
			term := "topic"
			config := RefreshConfig{AIModelConfig: writingConfig(provider.URL), AIModelQuotaLimiter: &groupDraftFixtureQuota{}, sentiment: client}
			result, err := generateGroupDraft(context.Background(), store, 42, "id", moderationPolicy{}, config, groupDraftRequest{Kind: "weekly_report", searchTerm: &term})
			if err != nil || result == nil || store.reads != 1 || store.written == nil || inferences.Load() != 2 {
				t.Fatal(result, err, store.reads, inferences.Load())
			}
			draft := store.written.GroupDraft
			if available {
				if predictions.Load() != 8 || draft.SentimentSourceDigest != groupSentimentSourceDigest(current, previous) || !slices.Contains(draft.ToolsUsed, sentimentContract.Tool.Name) {
					t.Fatal(predictions.Load(), draft)
				}
			} else if draft.SentimentSourceDigest != "" || slices.Contains(draft.ToolsUsed, sentimentContract.Tool.Name) {
				t.Fatal(draft)
			}
		})
	}
}

func TestSentimentHistoryRechecksPreviousWindowWithoutPlugin(t *testing.T) {
	current := sentimentDraftEvidence("2026-11-10T12:00:00.000000", "2026-11-17T12:00:00.000000", "current")
	previous := sentimentDraftEvidence("2026-11-03T12:00:00.000000", current.WindowStart, "previous")
	current.Examples = current.Examples[:1]
	previous.Examples = previous.Examples[:1]
	term := "topic"
	draft := groupDraftRecord{Version: 1, Kind: "weekly_report", WindowEnd: current.WindowEnd, SourceDigest: groupEvidenceDigest(current),
		ExampleCount: 1, SkillGeneration: 1, Draft: "Draft", ToolsUsed: []string{"public_search", sentimentContract.Tool.Name}, SearchTerm: &term,
		MatchExcerpt: true, SentimentSourceDigest: groupSentimentSourceDigest(current, previous)}
	state := &skillConfigState{}
	db := sql.OpenDB(groupDraftTxConnector{skillConfigConnector: skillConfigConnector{state}, evidence: current, previous: &previous})
	defer db.Close()
	ctx := context.Background()
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	if _, err := recheckGroupDraft(ctx, tx, 42, 7, &draft); err != nil {
		t.Fatal(err)
	}
	if len(state.conversation.calls) != 2 {
		t.Fatal("expected both source windows to be rechecked")
	}
	for _, call := range state.conversation.calls {
		var bound bool
		for _, arg := range call.args {
			bound = bound || (arg.Name == "search_term" && arg.Value == term)
		}
		if !bound {
			t.Fatal("historical search term was not bound")
		}
	}
	previous.Examples[0].Excerpt = "changed"
	if _, err := recheckGroupDraft(ctx, tx, 42, 7, &draft); !errors.Is(err, errConversationConflict) {
		t.Fatal("changed historical evidence was accepted", err)
	}
}

type sentimentQueueFixture struct {
	*dashboardFixture
	lookups []int64
}

func (s *sentimentQueueFixture) ModerationContent(_ context.Context, _ int64, _ contentQueueFilters, _ SessionPage, _ StorageURLPolicy) ([]contentQueueItem, int64, error) {
	rows := make([]contentQueueItem, 12)
	for i := range rows {
		rows[i] = contentQueueItem{CaseID: int64(i + 100), PostID: int64(i + 1), Content: "unsafe to use directly"}
	}
	return rows, 27, nil
}

func (s *sentimentQueueFixture) readContentQueueSentiment(_ context.Context, viewer, postID int64) (string, error) {
	s.lookups = append(s.lookups, postID)
	if viewer != 42 {
		return "", errConversationForbidden
	}
	if postID == 2 || postID == 4 {
		return "", nil
	}
	return fmt.Sprintf("eligible-%d", postID), nil
}

func TestSentimentModerationQueueOptInAndOrder(t *testing.T) {
	codec, tokens := fixture(t)
	repo := &sentimentQueueFixture{dashboardFixture: &dashboardFixture{memorySessions: store()}}
	client := configuredSentimentForTest(t)
	var predictions atomic.Int32
	client.http.Transport = knowledgeIndexTransportFunc(func(request *http.Request) (*http.Response, error) {
		predictions.Add(1)
		var input struct{ Text string }
		if json.NewDecoder(request.Body).Decode(&input) != nil || !strings.HasPrefix(input.Text, "eligible-") {
			t.Error("queue should classify the separately authorized public excerpt")
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"label":"neutral","confidence":0.75}`))}, nil
	})
	handler := NewHandlerWithConfig(codec, repo, CorsPolicy{}, RefreshConfig{ModerationAdminAccounts: "reviewer", sentiment: client})
	for _, optIn := range []bool{false, true} {
		path := "/api/v2/moderation/content"
		if optIn {
			path += "?sentiment_signal=1"
		}
		request := httptest.NewRequest(http.MethodGet, path, nil)
		request.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		var payload struct {
			Data []contentQueueItem
			Meta struct{ Total int }
		}
		if response.Code != 200 || json.Unmarshal(response.Body.Bytes(), &payload) != nil || len(payload.Data) != 12 || payload.Meta.Total != 27 {
			t.Fatal(response.Code, response.Body.String())
		}
		for i, item := range payload.Data {
			wantSignal := optIn && i < 10 && i != 1 && i != 3
			if item.PostID != int64(i+1) || (item.SentimentSignal != nil) != wantSignal || (wantSignal && item.SentimentSignal.Label != "neutral") {
				t.Fatal(item)
			}
		}
		if !optIn && (len(repo.lookups) != 0 || predictions.Load() != 0) {
			t.Fatal("non-opted-in queue consulted sentiment sources")
		}
	}
	if len(repo.lookups) != 10 || predictions.Load() != 8 {
		t.Fatal(repo.lookups, predictions.Load())
	}
}
