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
		row := []driver.Value{int64(11), int64(11), "public post"}
		if strings.Contains(query, "p.group_id AS group_id") {
			row = append(row, int64(7))
		}
		return &alertRows{values: row}, nil
	}
	if values["source_id"] == int64(21) {
		row := []driver.Value{int64(21), int64(11), "comment"}
		if strings.Contains(query, "p.group_id AS group_id") {
			row = append(row, int64(7))
		}
		return &alertRows{values: row}, nil
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
		for _, part := range []string{"p.visibility='public'", "p.is_deleted=0", "post_author.is_active=1", "fn_can_view_post(:viewer_id,p.post_id)=1", "DBMS_LOB.GETLENGTH("} {
			if !strings.Contains(call.sql, part) {
				t.Fatal(call.sql)
			}
		}
		if i == 1 {
			for _, part := range []string{"c.is_deleted=0", "p.post_id=c.post_id", "comment_author.is_active=1", "b.user_id=:viewer_id AND b.target_user_id=c.user_id", "b.target_user_id=:viewer_id AND b.user_id=c.user_id"} {
				if !strings.Contains(call.sql, part) {
					t.Fatal(call.sql)
				}
			}
		}
	}
}
func TestDatabaseKnowledgeReaderRejectsUnknownKinds(t *testing.T) {
	reader := oracleKnowledgeReader{}
	_, _, err := reader.get(context.Background(), 42, knowledgeCandidate{Kind: "unknown", ID: 3, Version: strings.Repeat("b", 64)})
	if !errors.Is(err, errKnowledgeInvalid) {
		t.Fatal(err)
	}
}

func TestGroupKnowledgeSourcesUsePublicGroupAuthority(t *testing.T) {
	state := &knowledgeDB{}
	db := sql.OpenDB(knowledgeConnector{state})
	defer db.Close()
	candidates := []knowledgeCandidate{
		{Kind: "group_post", ID: 11, Version: knowledgeSourceVersion("group_post", 11, 11, "public post")},
		{Kind: "group_comment", ID: 21, Version: knowledgeSourceVersion("group_comment", 21, 11, "comment")},
	}
	result, err := (OracleSessions{db}).hydrateKnowledgeSources(context.Background(), 42, candidates)
	if err != nil || len(result) != 2 || len(state.queries) != 2 {
		t.Fatal(result, err, state.queries)
	}
	for i, table := range []string{"n_group_posts", "n_group_comments"} {
		query := state.queries[i].sql
		if !strings.Contains(query, "FROM "+table) || !strings.Contains(query, "g.privacy='public' AND g.is_active=1 AND g.is_deleted=0") {
			t.Fatal(query)
		}
		if result[i].GroupID != 7 {
			t.Fatalf("missing verified group: %+v", result[i])
		}
	}
	if err := validateKnowledgeCandidates(42, candidates); err != nil {
		t.Fatal(err)
	}
	stored, err := encodeKnowledgeMessage("group answer", candidates)
	if err != nil || strings.Contains(stored, "group_id") {
		t.Fatal(stored, err)
	}
	restored, err := restoreKnowledgeMessage(context.Background(), stored, func(ctx context.Context, refs []knowledgeCandidate) ([]knowledgeSource, error) {
		return (OracleSessions{db}).hydrateKnowledgeSources(ctx, 42, refs)
	})
	if err != nil || len(restored.Citations) != 2 || restored.Citations[1].GroupID != 7 {
		t.Fatal(restored, err)
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
