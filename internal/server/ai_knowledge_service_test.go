package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
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
	if strings.Contains(query, "n_comments") {
		return &alertRows{values: []driver.Value{int64(21), int64(11), "评论猫"}}, nil
	}
	return &alertRows{values: []driver.Value{int64(11), int64(11), "帖子猫"}}, nil
}

type serviceDBTransport struct {
	db *sql.DB
	t  *testing.T
}

func (t serviceDBTransport) Infer(_ context.Context, _ ai.Selection, _ []byte) (ai.InferenceResult, error) {
	if t.db.Stats().InUse != 0 {
		t.t.Fatal("database connection held during inference")
	}
	return ai.InferenceResult{Text: "answer", FinishReason: "stop"}, nil
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

type knowledgeServiceFake struct {
	rows   []knowledgeSource
	events []string
	revoke bool
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
	if f.revoke {
		return nil, nil
	}
	return f.rows, nil
}

type knowledgeTransportFake struct {
	store  *knowledgeServiceFake
	input  []byte
	revoke bool
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
	return ai.InferenceResult{Text: "answer", FinishReason: "stop"}, nil
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
	if _, err := generateKnowledgeWithTransport(context.Background(), store, 42, "猫", selection, transport); !errors.Is(err, errKnowledgeContextTooLarge) {
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
