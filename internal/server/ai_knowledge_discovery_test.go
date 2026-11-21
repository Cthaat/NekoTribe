package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"reflect"
	"strings"
	"testing"
)

type knowledgeIndexTransportFunc func(*http.Request) (*http.Response, error)

func (f knowledgeIndexTransportFunc) RoundTrip(r *http.Request) (*http.Response, error) {
	return f(r)
}

func TestKnowledgeIndexFallbackVectors(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/ai-knowledge-index-fallback.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			ID             string  `json:"id"`
			Address        string  `json:"address"`
			NoRequest      bool    `json:"noRequest"`
			Query          *string `json:"query"`
			Limit          *int    `json:"limit"`
			Status         int     `json:"status"`
			Body           string  `json:"body"`
			Fallback       string  `json:"fallback"`
			Expect         string  `json:"expect"`
			TransportError bool    `json:"transportError"`
			Cancel         bool    `json:"cancel"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(raw, &fixture); err != nil || len(fixture.Cases) == 0 {
		t.Fatal("invalid fallback vectors")
	}
	_, digest := termsAuthorityFixtures(t)
	t.Setenv("AI_KNOWLEDGE_INDEX_URL", "http://index.example.test")
	t.Setenv("AI_INDEX_SERVICE_TOKEN", strings.Repeat("x", 32))
	for _, item := range fixture.Cases {
		t.Run(item.ID, func(t *testing.T) {
			if item.Address != "" {
				t.Setenv("AI_KNOWLEDGE_INDEX_URL", item.Address)
			}
			t.Setenv("AI_KNOWLEDGE_INDEX_FALLBACK", item.Fallback)
			original := knowledgeIndexHTTP
			client := *original
			knowledgeIndexHTTP = &client
			t.Cleanup(func() { knowledgeIndexHTTP = original })
			calls := 0
			client.Transport = knowledgeIndexTransportFunc(func(request *http.Request) (*http.Response, error) {
				calls++
				if request.Header.Get("X-Neko-Knowledge-Group-Sources") != "1" {
					t.Fatal("missing group source negotiation")
				}
				if item.ID == "ipv6-proxy-prefix" && request.URL.String() != "http://[::1]:3818/retrieval/internal/v1/knowledge/search" {
					t.Fatal("did not preserve the index proxy prefix")
				}
				if item.TransportError {
					return nil, errors.New("network failure")
				}
				return &http.Response{StatusCode: item.Status, Header: http.Header{"Location": {"http://redirect.example.test/"}}, Body: io.NopCloser(strings.NewReader(item.Body))}, nil
			})
			db := sql.OpenDB(sharedDiscoveryConnector{sharedDiscoveryCase{Query: "cats", Posts: []int64{11}}, digest})
			defer db.Close()
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			if item.Cancel {
				cancel()
			}
			query, limit := "cats", 20
			if item.Query != nil {
				query = *item.Query
			}
			if item.Limit != nil {
				limit = *item.Limit
			}
			rows, err := (OracleSessions{db}).discoverKnowledgeSources(ctx, 42, query, limit)
			if calls > 1 {
				t.Fatal("followed an index redirect")
			}
			if item.NoRequest && calls != 0 {
				t.Fatal("sent a request that should have been rejected before transport")
			}
			switch item.Expect {
			case "group":
				if err != nil || len(rows) != 1 || rows[0].Kind != "group_comment" || rows[0].ID != 21 || rows[0].Chunk == nil || *rows[0].Chunk != 2 {
					t.Fatal(rows, err)
				}
			case "error":
				if err == nil {
					t.Fatal("accepted an index failure")
				}
			case "lexical":
				if err != nil || len(rows) != 1 || rows[0].Kind != "post" || rows[0].ID != 11 {
					t.Fatalf("did not discover the expected lexical source: %v", err)
				}
			case "empty":
				if err != nil || len(rows) != 0 {
					t.Fatalf("did not preserve an empty result: %v", err)
				}
			default:
				t.Fatal("unknown expected result")
			}
		})
	}
}

type discoveryConnector struct{ state *knowledgeDB }
type discoveryConn struct {
	*testConn
	state *knowledgeDB
}

type sharedDiscoveryCase struct {
	ID            string   `json:"id"`
	Query         string   `json:"query"`
	Limit         int      `json:"limit"`
	Posts         []int64  `json:"posts"`
	Comments      []int64  `json:"comments"`
	GroupPosts    []int64  `json:"groupPosts"`
	GroupComments []int64  `json:"groupComments"`
	Authority     string   `json:"authority"`
	Expected      []string `json:"expected"`
	Error         bool     `json:"error"`
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
type sharedGroupDiscoveryRows struct{ termsAuthorityRows }

func (*sharedGroupDiscoveryRows) Columns() []string {
	return []string{"SOURCE_ID", "POST_ID", "CONTENT", "GROUP_ID"}
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
	group := strings.Contains(q, "FROM n_group_")
	comments := strings.Contains(q, "FROM n_comments") || strings.Contains(q, "FROM n_group_comments")
	if comments {
		ids = c.item.Comments
	}
	if group {
		ids = c.item.GroupPosts
		if comments {
			ids = c.item.GroupComments
		}
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
		row := []driver.Value{id, parent, fmt.Sprintf("%s %d", c.item.Query, id)}
		if group {
			row = append(row, int64(7))
		}
		values = append(values, row)
	}
	if group {
		return &sharedGroupDiscoveryRows{termsAuthorityRows{values: values}}, nil
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
	if strings.Contains(query, "FROM n_group_") {
		return &sharedGroupDiscoveryRows{}, nil
	}
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
		required := []string{"p.visibility='public'", "p.is_deleted=0", "post_author.is_active=1", "fn_can_view_post(:viewer_id,p.post_id)=1", "DBMS_LOB.INSTR(", ":term", "FETCH FIRST :row_limit ROWS ONLY"}
		if i >= 2 {
			required = []string{"g.privacy='public'", "g.is_active=1", "g.is_deleted=0", "p.is_deleted=0", "a.is_active=1", "FROM n_user_blocks", "INSTR(", ":term", "FETCH FIRST :row_limit ROWS ONLY"}
			required = append(required, "p.group_id BETWEEN 1 AND :max_id")
		}
		required = append(required, "p.post_id BETWEEN 1 AND :max_id")
		if i == 1 || i == 3 {
			required = append(required, "c.comment_id BETWEEN 1 AND :max_id")
		}
		for _, part := range required {
			if !strings.Contains(call.sql, part) {
				t.Fatal(call.sql)
			}
		}
		if i == 1 {
			for _, part := range []string{"c.is_deleted=0", "comment_author.is_active=1", "b.user_id=:viewer_id AND b.target_user_id=c.user_id", "b.target_user_id=:viewer_id AND b.user_id=c.user_id"} {
				if !strings.Contains(call.sql, part) {
					t.Fatal(call.sql)
				}
			}
		}
		args := map[string]driver.Value{}
		for _, a := range call.args {
			args[a.Name] = a.Value
		}
		if args["viewer_id"] != int64(42) || args["term"] != "猫" || args["row_limit"] != int64(2) || args["max_id"] != int64(999_999_999_999_999) {
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
	if err != nil || len(rows) != 2 || rows[0].ID != 11 || rows[1].ID != 21 || rows[1].Version != knowledgeSourceVersion("comment", 21, 11, "评论猫") || f.calls != 5 {
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
