package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"io"
	"os"
	"strings"
	"testing"
)

type termsAuthorityState struct {
	values           [][]driver.Value
	err              error
	calls            int
	includePost      bool
	includeComment   bool
	lastAuthoritySQL string
}
type termsAuthorityConnector struct{ state *termsAuthorityState }
type termsAuthorityConn struct {
	*testConn
	state *termsAuthorityState
}
type termsAuthorityRows struct {
	values [][]driver.Value
	index  int
}

func (c termsAuthorityConnector) Connect(context.Context) (driver.Conn, error) {
	return &termsAuthorityConn{&testConn{&driverState{}}, c.state}, nil
}
func (termsAuthorityConnector) Driver() driver.Driver { return testDriver{} }
func (c *termsAuthorityConn) QueryContext(_ context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	c.state.calls++
	if c.state.includeComment && strings.Contains(q, "FROM n_comments") {
		return &alertRows{values: []driver.Value{int64(21), int64(11), "账户评论"}}, nil
	}
	if c.state.includePost && strings.Contains(q, "FROM n_posts") {
		if len(args) == 3 {
			return &alertRows{values: []driver.Value{int64(11), int64(11), "账户帖子"}}, nil
		}
		if len(args) != 2 || args[0].Name != "source_id" || args[0].Value != int64(11) || args[1].Name != "viewer_id" || args[1].Value != int64(42) {
			return nil, errors.New("unexpected post query")
		}
		return &alertRows{values: []driver.Value{int64(11), int64(11), "public post"}}, nil
	}
	if !strings.Contains(strings.ToLower(q), "from n_ai_terms_active") || len(args) != 1 || args[0].Name != "singleton_id" || args[0].Value != int64(1) {
		return nil, errors.New("unexpected query")
	}
	c.state.lastAuthoritySQL = q
	if c.state.err != nil {
		return nil, c.state.err
	}
	return &termsAuthorityRows{values: c.state.values}, nil
}

func TestKnowledgeTermsLockIsExplicitAndTransactionScoped(t *testing.T) {
	raw, digest := termsAuthorityFixtures(t)
	catalog, err := parsePublicTermsCatalog(raw)
	if err != nil {
		t.Fatal(err)
	}
	state := &termsAuthorityState{values: [][]driver.Value{{digest, int64(1), int64(1)}}}
	db := sql.OpenDB(termsAuthorityConnector{state})
	defer db.Close()
	ref := knowledgeCandidate{Kind: "terms", ID: 1, Version: catalog[0].Version}
	if _, err := hydrateKnowledge(context.Background(), oracleKnowledgeReader{db}, 42, []knowledgeCandidate{ref}); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(state.lastAuthoritySQL, "FOR UPDATE") {
		t.Fatal(state.lastAuthoritySQL)
	}
	tx, err := db.BeginTx(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	if _, err = hydrateKnowledge(context.Background(), lockedKnowledgeReader{tx}, 42, []knowledgeCandidate{ref}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(state.lastAuthoritySQL, "FOR UPDATE WAIT 5") {
		t.Fatal(state.lastAuthoritySQL)
	}
}
func (r *termsAuthorityRows) Columns() []string {
	return []string{"CATALOG_DIGEST", "GENERATION", "ENABLED"}
}
func (r *termsAuthorityRows) Close() error { return nil }
func (r *termsAuthorityRows) Next(dest []driver.Value) error {
	if r.index == len(r.values) {
		return io.EOF
	}
	copy(dest, r.values[r.index])
	r.index++
	return nil
}

func termsAuthorityFixtures(t *testing.T) ([]byte, string) {
	t.Helper()
	raw, err := os.ReadFile("../../contracts/requirements/ai-public-terms-catalog.json")
	if err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile("../../contracts/scenarios/ai-public-terms-source-vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		Digest string `json:"catalog_digest"`
	}
	if err = json.Unmarshal(b, &v); err != nil {
		t.Fatal(err)
	}
	return raw, v.Digest
}
func TestTermsAuthorityDigestSharedVector(t *testing.T) {
	raw, want := termsAuthorityFixtures(t)
	got, err := publicTermsCatalogDigest(raw)
	if err != nil || got != want {
		t.Fatal(got, want, err)
	}
	var pack map[string]json.RawMessage
	if json.Unmarshal(raw, &pack) != nil {
		t.Fatal("decode")
	}
	var docs []json.RawMessage
	if json.Unmarshal(pack["documents"], &docs) != nil {
		t.Fatal("documents")
	}
	for i, j := 0, len(docs)-1; i < j; i, j = i+1, j-1 {
		docs[i], docs[j] = docs[j], docs[i]
	}
	pack["documents"], _ = json.Marshal(docs)
	reordered, _ := json.Marshal(pack)
	if d, e := publicTermsCatalogDigest(reordered); e != nil || d != want {
		t.Fatal(d, e)
	}
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(docs[0], &doc); err != nil {
		t.Fatal(err)
	}
	doc["title"], _ = json.Marshal("Changed title")
	docs[0], _ = json.Marshal(doc)
	pack["documents"], _ = json.Marshal(docs)
	changed, _ := json.Marshal(pack)
	if d, e := publicTermsCatalogDigest(changed); e != nil || d == want {
		t.Fatal(d, e)
	}
	if _, e := publicTermsCatalogDigest([]byte(`{}`)); e == nil {
		t.Fatal("invalid catalog accepted")
	}
}
func TestTermsAuthorityRequiresCurrentEnabledSingleton(t *testing.T) {
	raw, digest := termsAuthorityFixtures(t)
	valid := []driver.Value{digest, int64(7), int64(1)}
	tests := []struct {
		name string
		rows [][]driver.Value
		err  error
		ok   bool
	}{
		{"current", [][]driver.Value{valid}, nil, true}, {"missing", nil, nil, false}, {"duplicate", [][]driver.Value{valid, valid}, nil, false},
		{"disabled", [][]driver.Value{{digest, int64(7), int64(0)}}, nil, false}, {"stale", [][]driver.Value{{strings.Repeat("0", 64), int64(7), int64(1)}}, nil, false},
		{"zero generation", [][]driver.Value{{digest, int64(0), int64(1)}}, nil, false}, {"oversized generation", [][]driver.Value{{digest, int64(1000000000000000), int64(1)}}, nil, false},
		{"fraction", [][]driver.Value{{digest, float64(1.5), int64(1)}}, nil, false}, {"db error", nil, errors.New("secret"), false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			state := &termsAuthorityState{values: tc.rows, err: tc.err}
			db := sql.OpenDB(termsAuthorityConnector{state})
			defer db.Close()
			got, err := readPublicTermsAuthority(context.Background(), db, 42, raw)
			if tc.ok {
				if err != nil || got.Generation != 7 || got.Digest != digest {
					t.Fatal(got, err)
				}
			} else if !errors.Is(err, errTermsAuthorityUnavailable) {
				t.Fatal(got, err)
			}
			if state.calls != 1 {
				t.Fatal(state.calls)
			}
		})
	}
	state := &termsAuthorityState{}
	db := sql.OpenDB(termsAuthorityConnector{state})
	defer db.Close()
	if _, err := readPublicTermsAuthority(context.Background(), db, 0, raw); !errors.Is(err, errKnowledgeInvalid) || state.calls != 0 {
		t.Fatal(err, state.calls)
	}
}

func TestKnowledgeTermsUsesCurrentAuthorityForHydration(t *testing.T) {
	raw, digest := termsAuthorityFixtures(t)
	catalog, err := parsePublicTermsCatalog(raw)
	if err != nil {
		t.Fatal(err)
	}
	ref := knowledgeCandidate{Kind: "terms", ID: catalog[0].ID, Version: catalog[0].Version}
	state := &termsAuthorityState{values: [][]driver.Value{{digest, int64(1), int64(1)}}}
	db := sql.OpenDB(termsAuthorityConnector{state})
	defer db.Close()
	rows, err := (OracleSessions{db}).hydrateKnowledgeSources(context.Background(), 42, []knowledgeCandidate{ref})
	if err != nil || len(rows) != 1 || rows[0].Kind != "terms" || rows[0].PostID != 0 || rows[0].Version != ref.Version || rows[0].Content == "" {
		t.Fatal(rows, err)
	}
	state.values = [][]driver.Value{{digest, int64(2), int64(0)}}
	if _, err = (OracleSessions{db}).hydrateKnowledgeSources(context.Background(), 42, []knowledgeCandidate{ref}); err == nil {
		t.Fatal("disabled terms restored")
	}
	state.values = [][]driver.Value{{digest, int64(3), int64(1)}}
	ref.Version = strings.Repeat("0", 64)
	rows, err = (OracleSessions{db}).hydrateKnowledgeSources(context.Background(), 42, []knowledgeCandidate{ref})
	if err != nil || len(rows) != 0 {
		t.Fatal(rows, err)
	}
}

func TestMixedHistoryReloadsPostAndCurrentTerms(t *testing.T) {
	raw, digest := termsAuthorityFixtures(t)
	catalog, err := parsePublicTermsCatalog(raw)
	if err != nil {
		t.Fatal(err)
	}
	refs := []knowledgeCandidate{{Kind: "post", ID: 11, Version: knowledgeSourceVersion("post", 11, 11, "public post")}, {Kind: "terms", ID: 1, Version: catalog[0].Version}}
	encoded, err := encodeKnowledgeMessage("answer", refs)
	if err != nil {
		t.Fatal(err)
	}
	state := &termsAuthorityState{values: [][]driver.Value{{digest, int64(1), int64(1)}}, includePost: true}
	db := sql.OpenDB(termsAuthorityConnector{state})
	defer db.Close()
	restore := func() (knowledgeRestored, error) {
		return restoreKnowledgeMessage(context.Background(), encoded, func(ctx context.Context, c []knowledgeCandidate) ([]knowledgeSource, error) {
			return (OracleSessions{db}).hydrateKnowledgeSources(ctx, 42, c)
		})
	}
	result, err := restore()
	if err != nil || len(result.Citations) != 2 || result.Citations[0].PostID != 11 || result.Citations[1].Kind != "terms" || result.Citations[1].PostID != 0 {
		t.Fatal(result, err)
	}
	state.values = [][]driver.Value{{digest, int64(2), int64(0)}}
	if _, err = restore(); err == nil {
		t.Fatal("disabled terms restored")
	}
}
