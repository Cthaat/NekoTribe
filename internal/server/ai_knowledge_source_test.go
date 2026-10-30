package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"
)

type knowledgeDB struct {
	driverState
	queries []listQueryCall
}
type knowledgeConnector struct{ state *knowledgeDB }
type knowledgeConn struct {
	*testConn
	state *knowledgeDB
}

func (c knowledgeConnector) Connect(context.Context) (driver.Conn, error) {
	return &knowledgeConn{&testConn{&c.state.driverState}, c.state}, nil
}
func (knowledgeConnector) Driver() driver.Driver { return testDriver{} }
func (c *knowledgeConn) QueryContext(_ context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	c.state.queries = append(c.state.queries, listQueryCall{query, append([]driver.NamedValue(nil), args...)})
	values := map[string]driver.Value{}
	for _, a := range args {
		values[a.Name] = a.Value
	}
	if values["viewer_id"] != int64(42) {
		return nil, errors.New("incorrect actor")
	}
	if values["source_id"] == int64(11) {
		return &alertRows{values: []driver.Value{int64(11), int64(11), "public post"}}, nil
	}
	if values["source_id"] == int64(21) {
		return &alertRows{values: []driver.Value{int64(21), int64(11), "comment"}}, nil
	}
	return emptyRows{&c.state.driverState}, nil
}
func TestKnowledgeSourceRepositoryUsesCurrentPublicVisibility(t *testing.T) {
	state := &knowledgeDB{}
	db := sql.OpenDB(knowledgeConnector{state})
	defer db.Close()
	candidates := []knowledgeCandidate{{Kind: "post", ID: 11, Version: knowledgeSourceVersion("post", 11, 11, "public post")}, {Kind: "comment", ID: 21, Version: knowledgeSourceVersion("comment", 21, 11, "comment")}}
	result, err := (OracleSessions{db}).hydrateKnowledgeSources(context.Background(), 42, candidates)
	if err != nil || len(result) != 2 || db.Stats().InUse != 0 {
		t.Fatal(result, err, state)
	}
	for i, call := range state.queries {
		for _, part := range []string{"p.visibility='public'", "p.is_deleted=0", "fn_can_view_post(:viewer_id,p.post_id)=1", "DBMS_LOB.GETLENGTH("} {
			if !strings.Contains(call.sql, part) {
				t.Fatal(call.sql)
			}
		}
		if i == 1 && (!strings.Contains(call.sql, "c.is_deleted=0") || !strings.Contains(call.sql, "p.post_id=c.post_id")) {
			t.Fatal(call.sql)
		}
	}
}
func TestDatabaseKnowledgeReaderNeverTreatsTermsAsPosts(t *testing.T) {
	fake := &knowledgeFake{}
	terms := knowledgeCandidate{Kind: "terms", ID: 3, Version: strings.Repeat("b", 64)}
	if _, err := hydrateKnowledge(context.Background(), fake, 42, []knowledgeCandidate{terms}); !errors.Is(err, errKnowledgeInvalid) || fake.calls != 0 {
		t.Fatal(err, fake.calls)
	}
}

type knowledgeFake struct {
	rows   map[string]knowledgeSource
	err    error
	calls  int
	viewer int64
}

func (f *knowledgeFake) get(_ context.Context, viewer int64, c knowledgeCandidate) (knowledgeSource, bool, error) {
	f.calls++
	f.viewer = viewer
	if f.err != nil {
		return knowledgeSource{}, false, f.err
	}
	v, ok := f.rows[c.Kind]
	return v, ok, nil
}
func TestKnowledgeSourceVersionsSharedVectors(t *testing.T) {
	data, err := os.ReadFile("../../contracts/scenarios/ai-knowledge-source-vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	var root struct {
		Cases []struct {
			Kind    string `json:"kind"`
			ID      int64  `json:"source_id"`
			PostID  int64  `json:"post_id"`
			Content string `json:"content"`
			Version string `json:"version"`
		} `json:"cases"`
	}
	if err = json.Unmarshal(data, &root); err != nil {
		t.Fatal(err)
	}
	for _, v := range root.Cases {
		if got := knowledgeSourceVersion(v.Kind, v.ID, v.PostID, v.Content); got != v.Version {
			t.Fatalf("version mismatch %s", v.Kind)
		}
	}
}
func TestKnowledgeHydrationFiltersStaleMissingAndInvalid(t *testing.T) {
	content := "public post"
	valid := knowledgeCandidate{Kind: "post", ID: 11, Version: knowledgeSourceVersion("post", 11, 11, content)}
	fake := &knowledgeFake{rows: map[string]knowledgeSource{"post": {Kind: "post", ID: 11, PostID: 11, Content: content}}}
	out, err := hydrateKnowledge(context.Background(), fake, 42, []knowledgeCandidate{valid})
	if err != nil || len(out) != 1 || out[0].Content != content || fake.viewer != 42 {
		t.Fatal(out, err)
	}
	fake.rows["post"] = knowledgeSource{Kind: "post", ID: 11, PostID: 11, Content: "edited"}
	out, err = hydrateKnowledge(context.Background(), fake, 42, []knowledgeCandidate{valid})
	if err != nil || len(out) != 0 {
		t.Fatal(out, err)
	}
	fake.rows["post"] = knowledgeSource{Kind: "post", ID: 11, PostID: 12, Content: "edited"}
	if _, err = hydrateKnowledge(context.Background(), fake, 42, []knowledgeCandidate{valid}); !errors.Is(err, errSessionStore) {
		t.Fatal(err)
	}
	if _, err = hydrateKnowledge(context.Background(), fake, 42, []knowledgeCandidate{valid, valid}); !errors.Is(err, errKnowledgeInvalid) {
		t.Fatal(err)
	}
	if _, err = hydrateKnowledge(context.Background(), fake, 0, []knowledgeCandidate{valid}); !errors.Is(err, errKnowledgeInvalid) {
		t.Fatal(err)
	}
	fake.rows["post"] = knowledgeSource{Kind: "post", ID: 11, PostID: 11, Content: strings.Repeat("猫", 21846)}
	out, err = hydrateKnowledge(context.Background(), fake, 42, []knowledgeCandidate{valid})
	if err != nil || len(out) != 0 {
		t.Fatal(out, err)
	}
	fake.rows["post"] = knowledgeSource{Kind: "post", ID: 11, PostID: 11, Content: string([]byte{0xff})}
	if _, err = hydrateKnowledge(context.Background(), fake, 42, []knowledgeCandidate{valid}); !errors.Is(err, errSessionStore) {
		t.Fatal(err)
	}
	delete(fake.rows, "post")
	if out, err = hydrateKnowledge(context.Background(), fake, 42, []knowledgeCandidate{valid}); err != nil || len(out) != 0 {
		t.Fatal(out, err)
	}
	fake.err = errors.New("private error")
	if _, err = hydrateKnowledge(context.Background(), fake, 42, []knowledgeCandidate{valid}); !errors.Is(err, errSessionStore) || strings.Contains(err.Error(), "private") {
		t.Fatal(err)
	}
}
