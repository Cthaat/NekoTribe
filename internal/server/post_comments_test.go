package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type commentsFixture struct {
	*memorySessions
	user, post                   int64
	query                        CommentListQuery
	visible, fail, missingAuthor bool
	selfAuthor                   bool
	calls                        int
}

type commentsConnector struct {
	calls  *[]listQueryCall
	hidden bool
	state  *driverState
}
type commentsConn struct {
	*testConn
	calls  *[]listQueryCall
	hidden bool
}

func (c commentsConnector) Connect(context.Context) (driver.Conn, error) {
	return &commentsConn{&testConn{c.state}, c.calls, c.hidden}, nil
}
func (c commentsConnector) Driver() driver.Driver { return testDriver{} }
func (c *commentsConn) QueryContext(_ context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	*c.calls = append(*c.calls, listQueryCall{query, append([]driver.NamedValue(nil), args...)})
	if strings.Contains(query, "FROM n_posts p") {
		if c.hidden {
			return emptyRows{c.state}, nil
		}
		return &alertRows{values: []driver.Value{int64(1)}}, nil
	}
	if strings.HasPrefix(query, "SELECT COUNT") {
		return &alertRows{values: []driver.Value{int64(4)}}, nil
	}
	at := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	return &alertRows{values: []driver.Value{int64(9), int64(1), int64(7), nil, int64(3), "text", at, at, int64(2), int64(1), int64(1)}}, nil
}
func TestPostCommentsRepositoryFiltersAndMaps(t *testing.T) {
	for _, tc := range []struct{ sort, order string }{{"newest", "c.created_at DESC"}, {"oldest", "c.created_at ASC"}, {"popular", "c.likes_count DESC, c.created_at DESC"}, {"unknown", "c.created_at DESC"}} {
		var calls []listQueryCall
		db := sql.OpenDB(commentsConnector{&calls, false, &driverState{}})
		items, total, visible, err := (OracleSessions{db}).ListPostComments(context.Background(), 42, 1, CommentListQuery{Page: SessionPage{Page: 2, PageSize: 3, Start: 4, End: 6}, Sort: tc.sort})
		db.Close()
		if err != nil || !visible || total != 4 || len(items) != 1 || items[0].ID != 9 || items[0].AuthorID != 7 || items[0].RootID == nil || *items[0].RootID != 3 || !items[0].Liked || items[0].CreatedAt != "2026-01-02T03:04:05.000Z" {
			t.Fatal(items, total, visible, err)
		}
		if len(calls) != 3 {
			t.Fatal(calls)
		}
		for _, call := range calls {
			if !strings.Contains(call.sql, "fn_can_view_post(:viewer_id,") {
				t.Fatal(call.sql)
			}
			args := map[string]any{}
			for _, arg := range call.args {
				args[arg.Name] = arg.Value
			}
			if args["viewer_id"] != int64(42) || args["post_id"] != int64(1) {
				t.Fatal(args)
			}
		}
		if !strings.Contains(calls[2].sql, "ORDER BY "+tc.order) {
			t.Fatal(calls[2].sql)
		}
		for _, call := range calls[1:] {
			for _, part := range []string{"post_author.is_active=1", "comment_author.is_active=1", "b.user_id=:viewer_id AND b.target_user_id=c.user_id", "b.target_user_id=:viewer_id AND b.user_id=c.user_id"} {
				if !strings.Contains(call.sql, part) {
					t.Fatal(call.sql)
				}
			}
		}
	}
	var calls []listQueryCall
	db := sql.OpenDB(commentsConnector{&calls, true, &driverState{}})
	defer db.Close()
	_, _, visible, err := (OracleSessions{db}).ListPostComments(context.Background(), 42, 2, CommentListQuery{})
	if err != nil || visible || len(calls) != 1 {
		t.Fatal(visible, err, calls)
	}
}

func TestPostCommentsRepositoryTargetsTheAuthorizedPost(t *testing.T) {
	var calls []listQueryCall
	db := sql.OpenDB(commentsConnector{&calls, false, &driverState{}})
	defer db.Close()
	query := CommentListQuery{CommentID: 9, Page: SessionPage{Page: 1, PageSize: 1, Start: 1, End: 1}}
	items, total, visible, err := (OracleSessions{db}).ListPostComments(context.Background(), 42, 1, query)
	if err != nil || !visible || len(items) != 1 || total != 1 || len(calls) != 2 {
		t.Fatal(items, total, visible, err, calls)
	}
	lookup := calls[1]
	if !strings.Contains(lookup.sql, "c.comment_id=:comment_id") ||
		!strings.Contains(lookup.sql, "fn_can_view_post(:viewer_id,c.post_id)=1") ||
		!strings.Contains(lookup.sql, "comment_author.is_active=1") ||
		!strings.Contains(lookup.sql, "FROM n_user_blocks") {
		t.Fatal(lookup.sql)
	}
	params := map[string]any{}
	for _, arg := range lookup.args {
		params[arg.Name] = arg.Value
	}
	if params["comment_id"] != int64(9) || params["post_id"] != int64(1) || params["viewer_id"] != int64(42) {
		t.Fatal(params)
	}
}

func (s *commentsFixture) ListPostComments(_ context.Context, user, post int64, query CommentListQuery) ([]PostComment, int64, bool, error) {
	s.user, s.post, s.query = user, post, query
	s.calls++
	if s.fail {
		return nil, 0, false, errors.New("private comments error")
	}
	if !s.visible {
		return nil, 0, false, nil
	}
	author := int64(7)
	if s.selfAuthor {
		author = user
	}
	return []PostComment{{ID: 9, PostID: post, AuthorID: author, Content: "hello", LikesCount: 3, Liked: true}}, 1, true, nil
}
func (s *commentsFixture) PublicProfile(_ context.Context, viewer, target int64) (PublicUser, bool, error) {
	author := int64(7)
	if s.selfAuthor {
		author = 42
	}
	if viewer != 42 || target != author {
		return PublicUser{}, false, errors.New("wrong viewer")
	}
	return PublicUser{UserID: author, Username: "author"}, !s.missingAuthor, nil
}

func TestPostCommentsAllowsOnlyAuthorToDelete(t *testing.T) {
	codec, tokens := fixture(t)
	store := &commentsFixture{memorySessions: store(), visible: true, selfAuthor: true}
	r := httptest.NewRequest("GET", "/api/v2/posts/1/comments", nil)
	r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
	w := httptest.NewRecorder()
	NewHandler(codec, store, CorsPolicy{}).ServeHTTP(w, r)
	var body struct {
		Data []struct {
			Viewer struct {
				CanDelete bool `json:"can_delete"`
			} `json:"viewer_state"`
		} `json:"data"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil || w.Code != 200 || len(body.Data) != 1 || !body.Data[0].Viewer.CanDelete {
		t.Fatal(w.Code, w.Body.String(), err)
	}
}
func TestPostCommentsRoute(t *testing.T) {
	codec, tokens := fixture(t)
	for _, tc := range []struct {
		name, path, token      string
		visible, fail, missing bool
		status, calls          int
	}{
		{"unauthorized", "/api/v2/posts/1/comments", "", true, false, false, 401, 0},
		{"invalid id", "/api/v2/posts/01/comments", tokens["access-hs256"], true, false, false, 400, 0},
		{"hidden", "/api/v2/posts/2/comments", tokens["access-hs256"], false, false, false, 404, 1},
		{"database error", "/api/v2/posts/1/comments", tokens["access-hs256"], true, true, false, 500, 1},
		{"author missing", "/api/v2/posts/1/comments", tokens["access-hs256"], true, false, true, 404, 1},
		{"visible", "/api/v2/posts/1/comments?sort=popular&page=2&page_size=3&viewer_id=99", tokens["access-hs256"], true, false, false, 200, 1},
		{"targeted", "/api/v2/posts/1/comments?comment_id=9&page=2", tokens["access-hs256"], true, false, false, 200, 1},
		{"duplicate selector", "/api/v2/posts/1/comments?comment_id=9&comment_id=9", tokens["access-hs256"], true, false, false, 400, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := &commentsFixture{memorySessions: store(), visible: tc.visible, fail: tc.fail, missingAuthor: tc.missing}
			h := NewHandlerWithConfig(codec, s, CorsPolicy{}, RefreshConfig{})
			r := httptest.NewRequest("GET", tc.path, nil)
			if tc.token != "" {
				r.Header.Set("Authorization", "Bearer "+tc.token)
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			if w.Code != tc.status || s.calls != tc.calls || strings.Contains(w.Body.String(), "private comments") {
				t.Fatalf("status=%d calls=%d body=%s", w.Code, s.calls, w.Body.String())
			}
			if w.Header().Get("Cache-Control") != "private, no-store" {
				t.Fatal(w.Header())
			}
			if tc.calls > 0 && s.user != 42 {
				t.Fatal(s.user)
			}
			if tc.status == 200 {
				var result struct {
					Data []struct {
						ID          int64      `json:"comment_id"`
						Author      PublicUser `json:"author"`
						ViewerState struct {
							Liked     bool `json:"is_liked"`
							CanDelete bool `json:"can_delete"`
						} `json:"viewer_state"`
					} `json:"data"`
					Meta map[string]any `json:"meta"`
				}
				if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil || len(result.Data) != 1 || result.Data[0].ID != 9 || result.Data[0].Author.UserID != 7 || !result.Data[0].ViewerState.Liked || result.Data[0].ViewerState.CanDelete {
					t.Fatal(result, err, s.query)
				}
				if tc.name == "targeted" {
					if s.query.CommentID != 9 || s.query.Page != (SessionPage{Page: 1, PageSize: 1, Start: 1, End: 1}) {
						t.Fatal(s.query)
					}
				} else if result.Meta["page"] != float64(2) || s.query.Sort != "popular" {
					t.Fatal(result, s.query)
				}
			}
		})
	}
}
