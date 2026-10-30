package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"
)

type discoveryConnector struct{ state *knowledgeDB }
type discoveryConn struct {
	*testConn
	state *knowledgeDB
}

type sharedDiscoveryCase struct {
	ID        string   `json:"id"`
	Query     string   `json:"query"`
	Limit     int      `json:"limit"`
	Posts     []int64  `json:"posts"`
	Comments  []int64  `json:"comments"`
	Authority string   `json:"authority"`
	Expected  []string `json:"expected"`
	Error     bool     `json:"error"`
}
type sharedDiscoveryConnector struct {
	item   sharedDiscoveryCase
	digest string
}
type sharedDiscoveryConn struct {
	*testConn
	item   sharedDiscoveryCase
	digest string
}

func (c sharedDiscoveryConnector) Connect(context.Context) (driver.Conn, error) {
	return &sharedDiscoveryConn{&testConn{&driverState{}}, c.item, c.digest}, nil
}
func (sharedDiscoveryConnector) Driver() driver.Driver { return testDriver{} }
func (c *sharedDiscoveryConn) QueryContext(_ context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	if strings.Contains(strings.ToLower(q), "from n_ai_terms_active") {
		v := int64(0)
		if c.item.Authority == "enabled" {
			v = 1
		}
		return &termsAuthorityRows{values: [][]driver.Value{{c.digest, int64(1), v}}}, nil
	}
	ids := c.item.Posts
	comments := strings.Contains(q, "FROM n_comments")
	if comments {
		ids = c.item.Comments
	}
	var limit int64
	for _, a := range args {
		if a.Name == "row_limit" {
			limit = a.Value.(int64)
		}
	}
	values := [][]driver.Value{}
	for i, id := range ids {
		if int64(i) >= limit {
			break
		}
		parent := id
		if comments {
			parent = 11
		}
		values = append(values, []driver.Value{id, parent, fmt.Sprintf("%s %d", c.item.Query, id)})
	}
	return &termsAuthorityRows{values: values}, nil
}
func TestSharedDiscoveryOrderVectors(t *testing.T) {
	data, err := os.ReadFile("../../contracts/scenarios/ai-knowledge-discovery-order.json")
	if err != nil {
		t.Fatal(err)
	}
	var vectors struct {
		Cases []sharedDiscoveryCase `json:"cases"`
	}
	if err = json.Unmarshal(data, &vectors); err != nil {
		t.Fatal(err)
	}
	_, digest := termsAuthorityFixtures(t)
	for _, item := range vectors.Cases {
		t.Run(item.ID, func(t *testing.T) {
			db := sql.OpenDB(sharedDiscoveryConnector{item, digest})
			defer db.Close()
			rows, err := (OracleSessions{db}).discoverKnowledgeSources(context.Background(), 42, item.Query, item.Limit)
			if item.Error {
				if err == nil {
					t.Fatal("expected authority error")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			got := []string{}
			for _, row := range rows {
				got = append(got, fmt.Sprintf("%s:%d", row.Kind, row.ID))
			}
			if !reflect.DeepEqual(got, item.Expected) {
				t.Fatal(got, item.Expected)
			}
		})
	}
}

func (c discoveryConnector) Connect(context.Context) (driver.Conn, error) {
	return &discoveryConn{&testConn{&c.state.driverState}, c.state}, nil
}
func (discoveryConnector) Driver() driver.Driver { return testDriver{} }
func (c *discoveryConn) QueryContext(_ context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	c.state.queries = append(c.state.queries, listQueryCall{query, append([]driver.NamedValue(nil), args...)})
	if strings.Contains(query, "FROM n_comments") {
		return &alertRows{values: []driver.Value{int64(21), int64(11), "评论猫"}}, nil
	}
	return &alertRows{values: []driver.Value{int64(11), int64(11), "帖子猫"}}, nil
}

func TestKnowledgeDiscoveryRepositoryBindsAndFilters(t *testing.T) {
	state := &knowledgeDB{}
	db := sql.OpenDB(discoveryConnector{state})
	defer db.Close()
	rows, err := (OracleSessions{db}).discoverKnowledgeSources(context.Background(), 42, "猫", 2)
	if err != nil || len(rows) != 2 || db.Stats().InUse != 0 {
		t.Fatal(rows, err)
	}
	for i, call := range state.queries {
		for _, part := range []string{"p.visibility='public'", "p.is_deleted=0", "fn_can_view_post(:viewer_id,p.post_id)=1", "DBMS_LOB.INSTR(", ":term", "FETCH FIRST :row_limit ROWS ONLY"} {
			if !strings.Contains(call.sql, part) {
				t.Fatal(call.sql)
			}
		}
		if i == 1 && !strings.Contains(call.sql, "c.is_deleted=0") {
			t.Fatal(call.sql)
		}
		args := map[string]driver.Value{}
		for _, a := range call.args {
			args[a.Name] = a.Value
		}
		if args["viewer_id"] != int64(42) || args["term"] != "猫" || args["row_limit"] != int64(2) {
			t.Fatal(args)
		}
	}
}

type discoveryFake struct {
	rows  map[string][]knowledgeSource
	calls int
	err   error
}

func (f *discoveryFake) search(_ context.Context, viewer int64, kind, term string, limit int) ([]knowledgeSource, error) {
	f.calls++
	if viewer != 42 || term != "猫" || limit != 2 {
		return nil, errors.New("wrong search arguments")
	}
	return f.rows[kind], f.err
}

func TestKnowledgeDiscoveryInterleavesPublicSources(t *testing.T) {
	f := &discoveryFake{rows: map[string][]knowledgeSource{
		"post":    {{Kind: "post", ID: 11, PostID: 11, Content: "帖子猫"}, {Kind: "post", ID: 10, PostID: 10, Content: "旧帖子猫"}},
		"comment": {{Kind: "comment", ID: 21, PostID: 11, Content: "评论猫"}},
	}}
	rows, err := discoverKnowledge(context.Background(), f, 42, " 猫 ", 2)
	if err != nil || len(rows) != 2 || rows[0].ID != 11 || rows[1].ID != 21 || rows[1].Version != knowledgeSourceVersion("comment", 21, 11, "评论猫") || f.calls != 3 {
		t.Fatal(rows, err)
	}
}

func TestKnowledgeDiscoveryInterleavesCurrentTerms(t *testing.T) {
	raw, digest := termsAuthorityFixtures(t)
	catalog, err := parsePublicTermsCatalog(raw)
	if err != nil {
		t.Fatal(err)
	}
	state := &termsAuthorityState{values: [][]driver.Value{{digest, int64(1), int64(1)}}, includePost: true, includeComment: true}
	db := sql.OpenDB(termsAuthorityConnector{state})
	defer db.Close()
	rows, err := (OracleSessions{db}).discoverKnowledgeSources(context.Background(), 42, "账户", 3)
	if err != nil || len(rows) != 3 || rows[0].Kind != "post" || rows[1].Kind != "comment" || rows[2].Kind != "terms" || rows[2].ID != 2 || rows[2].Version != catalog[1].Version || rows[2].PostID != 0 {
		t.Fatal(rows, err)
	}
	state.values = [][]driver.Value{{digest, int64(2), int64(0)}}
	if _, err = (OracleSessions{db}).discoverKnowledgeSources(context.Background(), 42, "账户", 3); err == nil {
		t.Fatal("disabled authority accepted")
	}
}

func TestKnowledgeDiscoveryRejectsInvalidAndCorrupt(t *testing.T) {
	f := &discoveryFake{}
	for _, term := range []string{"", "a\x00b", strings.Repeat("x", 257), string([]byte{0xff})} {
		if _, err := discoverKnowledge(context.Background(), f, 42, term, 2); !errors.Is(err, errKnowledgeInvalid) {
			t.Fatal(term, err)
		}
	}
	if f.calls != 0 {
		t.Fatal("invalid request queried")
	}
	f.rows = map[string][]knowledgeSource{"post": {{Kind: "post", ID: 11, PostID: 12, Content: "猫"}}}
	if _, err := discoverKnowledge(context.Background(), f, 42, "猫", 2); !errors.Is(err, errSessionStore) {
		t.Fatal(err)
	}
}
