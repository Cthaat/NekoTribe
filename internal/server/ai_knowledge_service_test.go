package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/Cthaat/NekoTribe/backend-go/internal/ai"
)

type serviceConnector struct{ state *knowledgeDB }
type serviceConn struct {
	*testConn
	state *knowledgeDB
}

func (c serviceConnector) Connect(context.Context) (driver.Conn, error) {
	return &serviceConn{&testConn{&c.state.driverState}, c.state}, nil
}
func (serviceConnector) Driver() driver.Driver { return testDriver{} }
func (c *serviceConn) QueryContext(_ context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	if strings.Contains(query, "FROM n_group_") {
		return &sharedGroupDiscoveryRows{}, nil
	}
	if strings.Contains(query, "n_comments") {
		return &alertRows{values: []driver.Value{int64(21), int64(11), "评论猫"}}, nil
	}
	return &alertRows{values: []driver.Value{int64(11), int64(11), "帖子猫"}}, nil
}

type serviceDBTransport struct {
	db *sql.DB
	t  *testing.T
}

func (t serviceDBTransport) Infer(_ context.Context, _ ai.Selection, input []byte) (ai.InferenceResult, error) {
	if t.db.Stats().InUse != 0 {
		t.t.Fatal("database connection held during inference")
	}
	return ai.InferenceResult{Text: fakeKnowledgeAnswer(input), FinishReason: "stop"}, nil
}
func fakeKnowledgeAnswer(input []byte) string {
	var request struct {
		Messages []struct {
			Content string `json:"content"`
		} `json:"messages"`
	}
	if json.Unmarshal(input, &request) != nil || len(request.Messages) != 2 {
		return "invalid"
	}
	var payload struct {
		Sources []knowledgeSource `json:"sources"`
	}
	if json.Unmarshal([]byte(request.Messages[1].Content), &payload) != nil || len(payload.Sources) == 0 {
		return "invalid"
	}
	text, _ := json.Marshal(map[string]any{"answer": "answer", "citations": knowledgeCandidates(payload.Sources)})
	return string(text)
}
func TestKnowledgeServiceReleasesOracleConnectionBeforeInference(t *testing.T) {
	db := sql.OpenDB(serviceConnector{&knowledgeDB{}})
	defer db.Close()
	selection := ai.Selection{Role: "knowledge", ContextWindowTokens: 8192, MaxOutputTokens: 512}
	result, err := generateKnowledgeWithTransport(context.Background(), OracleSessions{db}, 42, "猫", selection, serviceDBTransport{db, t})
	if err != nil || result.Answer == nil || len(result.Sources) != 2 || db.Stats().InUse != 0 {
		t.Fatal(result, err, db.Stats())
	}
}

func TestKnowledgeServiceRefreshesAnObsoleteIndexHitOnlyWhenEnabled(t *testing.T) {
	for _, item := range []struct {
		name, fallback              string
		empty, invalidChunk, answer bool
	}{
		{"obsolete with fallback", "lexical", false, false, true},
		{"obsolete without fallback", "", false, false, false},
		{"empty with fallback", "lexical", true, false, false},
		{"out of bounds chunk with fallback", "lexical", false, true, true},
		{"out of bounds chunk without fallback", "", false, true, false},
	} {
		t.Run(item.name, func(t *testing.T) {
			index := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				candidates := []map[string]any{}
				if !item.empty {
					hit := map[string]any{"kind": "post", "id": 11, "version": strings.Repeat("a", 64)}
					if item.invalidChunk {
						hit["version"] = knowledgeSourceVersion("post", 11, 11, "帖子猫")
						hit["chunk"] = 1
					}
					candidates = append(candidates, hit)
				}
				_ = json.NewEncoder(w).Encode(map[string]any{"version": 1, "candidates": candidates})
			}))
			defer index.Close()
			t.Setenv("AI_KNOWLEDGE_INDEX_URL", index.URL)
			t.Setenv("AI_INDEX_SERVICE_TOKEN", strings.Repeat("x", 32))
			t.Setenv("AI_KNOWLEDGE_INDEX_FALLBACK", item.fallback)
			db := sql.OpenDB(serviceConnector{&knowledgeDB{}})
			defer db.Close()
			selection := ai.Selection{Role: "knowledge", ContextWindowTokens: 8192, MaxOutputTokens: 512}
			result, err := generateKnowledgeWithTransport(context.Background(), OracleSessions{db}, 42, "猫", selection, serviceDBTransport{db, t})
			if err != nil || (result.Answer != nil) != item.answer {
				t.Fatal(result, err)
			}
			if item.answer && (len(result.Sources) != 2 || result.Sources[0].Version != knowledgeSourceVersion("post", 11, 11, "帖子猫")) {
				t.Fatal("answer did not use the current Oracle version", result.Sources)
			}
		})
	}
}

type knowledgeServiceFake struct {
	rows       []knowledgeSource
	historical []knowledgeSource
	events     []string
	revoke     bool
	onHydrate  func()
}

func (f *knowledgeServiceFake) discoverKnowledgeSources(_ context.Context, user int64, query string, limit int) ([]knowledgeSource, error) {
	if user != 42 || query != "猫" || limit != 20 {
		return nil, errors.New("bad query")
	}
	f.events = append(f.events, "discover")
	return f.rows, nil
}
func (f *knowledgeServiceFake) hydrateKnowledgeSources(_ context.Context, user int64, candidates []knowledgeCandidate) ([]knowledgeSource, error) {
	if user != 42 {
		return nil, errors.New("bad user")
	}
	f.events = append(f.events, "hydrate")
	if f.onHydrate != nil {
		f.onHydrate()
	}
	if f.revoke {
		return nil, nil
	}
	var result []knowledgeSource
	for _, row := range append(append([]knowledgeSource(nil), f.rows...), f.historical...) {
		for _, candidate := range candidates {
			if row.Kind == candidate.Kind && row.ID == candidate.ID {
				result = append(result, row)
				break
			}
		}
	}
	return result, nil
}

type cancelledKnowledgeTransport struct{ cancel context.CancelFunc }

func (t cancelledKnowledgeTransport) Infer(context.Context, ai.Selection, []byte) (ai.InferenceResult, error) {
	t.cancel()
	return ai.InferenceResult{}, context.Canceled
}
func TestKnowledgeServicePreservesCancellationDuringInferenceAndHistoryCheck(t *testing.T) {
	source := knowledgeSource{Kind: "post", ID: 1, PostID: 1, Content: "资料", Version: strings.Repeat("a", 64)}
	selection := ai.Selection{Role: "knowledge", ContextWindowTokens: 8192, MaxOutputTokens: 512}
	ctx, cancel := context.WithCancel(context.Background())
	store := &knowledgeServiceFake{rows: []knowledgeSource{source}}
	if _, err := generateKnowledgeWithTransport(ctx, store, 42, "猫", selection, cancelledKnowledgeTransport{cancel}); !errors.Is(err, context.Canceled) {
		t.Fatalf("inference: %v", err)
	}
	ctx, cancel = context.WithCancel(context.Background())
	store = &knowledgeServiceFake{rows: []knowledgeSource{source}}
	store.onHydrate = func() {
		if strings.Contains(strings.Join(store.events, ","), "infer") {
			cancel()
			store.revoke = true
		}
	}
	history := []conversationHistoryMessage{{SequenceNo: 1, Role: "assistant", Content: "old", Citations: []knowledgeCitation{{Kind: "post", ID: 1, PostID: 1, Version: source.Version}}}, {SequenceNo: 2, Role: "user", Content: "猫"}}
	_, _, err := generateKnowledgeWithHistory(ctx, store, 42, "猫", selection, &knowledgeTransportFake{store: store}, history)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("history revalidation: %v", err)
	}
}

type knowledgeTransportFake struct {
	store        *knowledgeServiceFake
	input        []byte
	revoke       bool
	textOverride string
}

func (f *knowledgeTransportFake) Infer(_ context.Context, selection ai.Selection, input []byte) (ai.InferenceResult, error) {
	if selection.Role != "knowledge" {
		return ai.InferenceResult{}, errors.New("bad role")
	}
	f.store.events = append(f.store.events, "infer")
	f.input = append([]byte(nil), input...)
	if f.revoke {
		f.store.revoke = true
	}
	text := fakeKnowledgeAnswer(input)
	if f.textOverride != "" {
		text = f.textOverride
	}
	return ai.InferenceResult{Text: text, FinishReason: "stop"}, nil
}

func TestKnowledgeServiceRejectsInventedCitations(t *testing.T) {
	source := knowledgeSource{Kind: "post", ID: 1, PostID: 1, Content: "资料", Version: strings.Repeat("a", 64)}
	store := &knowledgeServiceFake{rows: []knowledgeSource{source}}
	text, _ := json.Marshal(map[string]any{"answer": "answer", "citations": []knowledgeCandidate{{Kind: "post", ID: 999, Version: source.Version}}})
	transport := &knowledgeTransportFake{store: store, textOverride: string(text)}
	selection := ai.Selection{Role: "knowledge", ContextWindowTokens: 8192, MaxOutputTokens: 512}
	if _, err := generateKnowledgeWithTransport(context.Background(), store, 42, "猫", selection, transport); !errors.Is(err, errKnowledgeCitations) {
		t.Fatal(err)
	}
}

func TestKnowledgeServiceConnectsSourcesAndInference(t *testing.T) {
	source := knowledgeSource{Kind: "post", ID: 1, PostID: 1, Content: "公开资料", Version: strings.Repeat("a", 64)}
	store := &knowledgeServiceFake{rows: []knowledgeSource{source}}
	transport := &knowledgeTransportFake{store: store}
	selection := ai.Selection{Role: "knowledge", ContextWindowTokens: 8192, MaxOutputTokens: 512}
	result, err := generateKnowledgeWithTransport(context.Background(), store, 42, "猫", selection, transport)
	if err != nil || result.Answer == nil || *result.Answer != "answer" || strings.Join(store.events, ",") != "discover,hydrate,infer,hydrate" {
		t.Fatal(result, err, store.events)
	}
	var request struct {
		Messages []struct{ Role, Content string } `json:"messages"`
	}
	if err = json.Unmarshal(transport.input, &request); err != nil {
		t.Fatal(err)
	}
	if len(request.Messages) != 2 || request.Messages[0].Role != "system" || !strings.Contains(request.Messages[0].Content, "不可信") || request.Messages[1].Role != "user" || !strings.Contains(request.Messages[1].Content, "公开资料") {
		t.Fatal(request)
	}
}

func TestKnowledgeServiceRejectsOversizeAndRevokedSources(t *testing.T) {
	source := knowledgeSource{Kind: "post", ID: 1, PostID: 1, Content: strings.Repeat("x", 20000), Version: strings.Repeat("a", 64)}
	store := &knowledgeServiceFake{rows: []knowledgeSource{source}}
	transport := &knowledgeTransportFake{store: store}
	selection := ai.Selection{Role: "knowledge", ContextWindowTokens: 8192, MaxOutputTokens: 512}
	tooSmall := selection
	tooSmall.ContextWindowTokens = tooSmall.MaxOutputTokens + 512
	if _, err := generateKnowledgeWithTransport(context.Background(), store, 42, "猫", tooSmall, transport); !errors.Is(err, errKnowledgeContextTooLarge) {
		t.Fatal(err)
	}
	if strings.Contains(strings.Join(store.events, ","), "infer") {
		t.Fatal(store.events)
	}
	store.rows[0].Content = "text"
	store.events = nil
	transport.revoke = true
	if _, err := generateKnowledgeWithTransport(context.Background(), store, 42, "猫", selection, transport); !errors.Is(err, errKnowledgeSourceChanged) {
		t.Fatal(err)
	}
}
