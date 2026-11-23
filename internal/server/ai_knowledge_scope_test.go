package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"

	"github.com/Cthaat/NekoTribe/backend-go/internal/ai"
)

func TestKnowledgeScopeCreateInput(t *testing.T) {
	for _, tc := range []struct {
		name string
		body map[string]any
		want knowledgeScope
	}{
		{"public default", map[string]any{"purpose": "knowledge"}, knowledgePublic},
		{"active group request", map[string]any{"purpose": "knowledge", "knowledge_scope": "group", "group_id": float64(17)}, knowledgeGroup},
		{"personal request", map[string]any{"purpose": "knowledge", "knowledge_scope": "personal"}, knowledgePersonal},
		{"personal with group", map[string]any{"purpose": "knowledge", "knowledge_scope": "personal", "group_id": float64(17)}, ""},
		{"group without target", map[string]any{"purpose": "knowledge", "knowledge_scope": "group"}, ""},
		{"other purpose", map[string]any{"purpose": "group", "knowledge_scope": "public", "group_id": float64(17)}, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			input, ok := parseAIConversationInput(tc.body)
			if ok != (tc.want != "") || (ok && input.KnowledgeScope != tc.want) {
				t.Fatalf("got scope=%q valid=%v, want %q", input.KnowledgeScope, ok, tc.want)
			}
		})
	}
}

func TestKnowledgeScopeListFilter(t *testing.T) {
	codec, tokens := fixture(t)
	for _, tc := range []struct {
		query  string
		status int
	}{
		{"knowledge_scope=group", 200},
		{"purpose=group&knowledge_scope=group", 400},
		{"knowledge_scope=public&knowledge_scope=group", 400},
	} {
		repo := &aiHTTPFixture{memorySessions: store()}
		r := httptest.NewRequest(http.MethodGet, "/api/v2/ai/conversations?"+tc.query, nil)
		r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		w := httptest.NewRecorder()
		NewHandlerWithConfig(codec, repo, CorsPolicy{}, RefreshConfig{}).ServeHTTP(w, r)
		if w.Code != tc.status || (w.Code == 200 && (repo.purpose != "knowledge" || repo.scope != knowledgeGroup)) {
			t.Fatal(tc.query, w.Code, repo.purpose, repo.scope)
		}
	}
}

func TestKnowledgeScopeHistoryHidesUnauthorizedEvidence(t *testing.T) {
	cited := knowledgeCandidate{Kind: "group_post", ID: 11, Version: knowledgeSourceVersion("group_post", 11, 11, "cited")}
	uncited := knowledgeCandidate{Kind: "group_post", ID: 12, Version: knowledgeSourceVersion("group_post", 12, 12, "uncited")}
	encoded, err := encodeKnowledgeMessageWithDependencies("answer", []knowledgeCandidate{cited}, []knowledgeCandidate{cited, uncited})
	if err != nil {
		t.Fatal(err)
	}
	restored, err := restoreKnowledgeMessage(context.Background(), encoded, func(_ context.Context, refs []knowledgeCandidate) ([]knowledgeSource, error) {
		if len(refs) != 2 || refs[0] != cited || refs[1] != uncited {
			t.Fatal(refs)
		}
		return []knowledgeSource{{Kind: cited.Kind, ID: cited.ID, Version: cited.Version, PostID: cited.ID, GroupID: 17}}, nil
	})
	if !errors.Is(err, errKnowledgeSourceChanged) || restored.Answer != nil || len(restored.Citations) != 0 {
		t.Fatal(restored, err)
	}
}

func TestKnowledgeScopeKeepsTransitivePromptDependencies(t *testing.T) {
	current := []knowledgeSource{
		{Kind: "post", ID: 1, PostID: 1, Version: strings.Repeat("a", 64), Content: "current cited"},
		{Kind: "post", ID: 2, PostID: 2, Version: strings.Repeat("b", 64), Content: "current dependency"},
	}
	historical := []knowledgeSource{
		{Kind: "post", ID: 3, PostID: 3, Version: strings.Repeat("c", 64), Content: "historical citation"},
		{Kind: "post", ID: 4, PostID: 4, Version: strings.Repeat("d", 64), Content: "historical dependency"},
	}
	old := historical[0]
	messages := []conversationHistoryMessage{
		{SequenceNo: 1, Role: "assistant", Content: "older answer", Citations: []knowledgeCitation{{Kind: old.Kind, ID: old.ID, PostID: old.PostID, Version: old.Version}}, KnowledgeDependencies: knowledgeCandidates(historical)},
		{SequenceNo: 2, Role: "user", Content: "猫"},
	}
	store := &knowledgeServiceFake{rows: current, historical: historical}
	citation := knowledgeCandidates(current[:1])
	modelAnswer, err := json.Marshal(map[string]any{"answer": "answer", "citations": citation})
	if err != nil {
		t.Fatal(err)
	}
	transport := &knowledgeTransportFake{store: store, textOverride: string(modelAnswer)}
	selection := ai.Selection{Role: "knowledge", ContextWindowTokens: 8192, MaxOutputTokens: 512}
	result, _, err := generateScopedKnowledgeWithHistory(context.Background(), store, 42, "猫", selection, transport, messages, knowledgePersonal)
	want := append(knowledgeCandidates(current), knowledgeCandidates(historical)...)
	if err != nil || !slices.Equal(result.Sources, citation) || !slices.Equal(result.Dependencies, want) {
		t.Fatal(err, result)
	}
}

func TestKnowledgeScopeSaveRechecksMembershipAndSources(t *testing.T) {
	id := "f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb"
	for _, tc := range []struct {
		name  string
		scope knowledgeScope
		kind  string
		group driver.Value
		mode  string
	}{
		{"active member", knowledgeGroup, "group_post", int64(17), ""},
		{"revoked before lock", knowledgeGroup, "group_post", int64(17), "member-revoked-before-lock"},
		{"revoked in flight", knowledgeGroup, "group_post", int64(17), "member-revoked-on-insert"},
		{"personal", knowledgePersonal, "post", nil, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ref := knowledgeCandidate{Kind: tc.kind, ID: 11, Version: knowledgeSourceVersion(tc.kind, 11, 11, "evidence")}
			state := &skillConfigState{conversation: conversationDB{owner: 42, id: id, purpose: "knowledge", knowledgeScope: string(tc.scope), group: tc.group, member: true, messages: 1, mode: tc.mode, revokeMemberOnInsert: tc.mode == "member-revoked-on-insert"}, rows: [][]driver.Value{{int64(1), `["knowledge-answer"]`}}}
			db := sql.OpenDB(skillConfigConnector{state})
			defer db.Close()
			input := assistantMessageInput{Content: "answer", ExpectedSequence: 1, ModelID: "profile", ConfigRevision: 1, SkillGeneration: 1, KnowledgeDependencies: []knowledgeCandidate{ref}}
			saved, err := (OracleSessions{db}).appendAIKnowledgeAssistantOperation(context.Background(), 42, id, input, []knowledgeCandidate{ref}, moderationPolicy{}, func(context.Context, *sql.Conn) error { return nil })
			calls := &state.conversation
			if tc.scope == knowledgeGroup {
				queries := scopedKnowledgeContract().SQL
				if !strings.HasSuffix(strings.ToUpper(queries["lock_membership"]), "FOR UPDATE OF GM.STATUS NOWAIT") {
					t.Fatal("expected an explicit membership row lock")
				}
				groupLock, memberLock, messageInsert := -1, -1, -1
				for i, call := range calls.calls {
					switch {
					case call.sql == queries["lock_group"]:
						groupLock = i
					case call.sql == queries["lock_membership"]:
						memberLock = i
					case strings.HasPrefix(call.sql, "INSERT INTO n_ai_messages"):
						messageInsert = i
					}
				}
				if groupLock < 0 || memberLock <= groupLock || (messageInsert >= 0 && messageInsert <= memberLock) {
					t.Fatal("expected group lock, then membership lock, then optional insert", groupLock, memberLock, messageInsert)
				}
				if tc.mode == "member-revoked-before-lock" && messageInsert >= 0 {
					t.Fatal("message insert attempted after membership was revoked")
				}
			}
			if tc.mode != "" {
				if !errors.Is(err, errConversationForbidden) || saved.ID != "" || calls.commits != 0 || calls.rollbacks != 1 {
					t.Fatal(err, saved, calls.commits, calls.rollbacks)
				}
				return
			}
			if err != nil || saved.SequenceNo != 2 || calls.commits != 1 || calls.knowledgeQueries != 2 || !strings.Contains(calls.messageContent, `"version":2`) {
				t.Fatal(err, saved, calls.commits, calls.knowledgeQueries, calls.messageContent)
			}
		})
	}
}

func TestKnowledgeScopeGroupIndexRequiresActiveMemberAndMatchingGroup(t *testing.T) {
	const viewer, group = int64(42), int64(17)
	state := &conversationDB{group: group}
	db := sql.OpenDB(conversationConnector{state})
	defer db.Close()
	access := conversationInput{Purpose: "knowledge", KnowledgeScope: knowledgeGroup}
	target := group
	access.GroupID = &target
	store := (OracleSessions{db}).knowledgeStoreForConversation(access)
	t.Setenv("AI_KNOWLEDGE_INDEX_URL", "http://index.example.test")
	t.Setenv("AI_INDEX_SERVICE_TOKEN", strings.Repeat("x", 32))
	client := *knowledgeIndexHTTP
	original := knowledgeIndexHTTP
	knowledgeIndexHTTP = &client
	t.Cleanup(func() { knowledgeIndexHTTP = original })
	calls := 0
	responseGroup := group
	version := knowledgeSourceVersion("group_post", 11, 11, "evidence")
	client.Transport = knowledgeIndexTransportFunc(func(request *http.Request) (*http.Response, error) {
		calls++
		var requestBody struct {
			Query   string `json:"query"`
			Limit   int    `json:"limit"`
			GroupID int64  `json:"group_id"`
		}
		if request.URL.Path != "/internal/v1/knowledge/group-search" || request.Method != http.MethodPost || json.NewDecoder(request.Body).Decode(&requestBody) != nil || requestBody.Query != "question" || requestBody.Limit != 20 || requestBody.GroupID != group {
			t.Fatal("incorrect scoped request", request.URL.Path, requestBody)
		}
		body, _ := json.Marshal(map[string]any{"version": 1, "group_id": responseGroup, "candidates": []knowledgeCandidate{{Kind: "group_post", ID: 11, Version: version}}})
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(string(body)))}, nil
	})
	ctx := context.Background()
	if _, err := store.discoverKnowledgeSources(ctx, viewer, "question", 20); !errors.Is(err, errConversationForbidden) || calls != 0 {
		t.Fatal(err, calls)
	}
	state.member = true
	hits, err := store.discoverKnowledgeSources(ctx, viewer, "question", 20)
	if err != nil || len(hits) != 1 || calls != 1 {
		t.Fatal(err, hits, calls)
	}
	rows, err := store.hydrateKnowledgeSources(ctx, viewer, knowledgeCandidates(hits))
	if err != nil || len(rows) != 1 || rows[0].GroupID != group {
		t.Fatal(err, rows)
	}
	state.mode = "cross-group-source"
	rows, err = store.hydrateKnowledgeSources(ctx, viewer, knowledgeCandidates(hits))
	if err != nil || len(rows) != 0 {
		t.Fatal(err, rows)
	}
	responseGroup++
	if hits, err = store.discoverKnowledgeSources(ctx, viewer, "question", 20); !errors.Is(err, errKnowledgeProvider) || len(hits) != 0 {
		t.Fatal(err, hits)
	}
}
