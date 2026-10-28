package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"strings"
	"testing"
	"time"
)

type listQueryCall struct {
	sql  string
	args []driver.NamedValue
}
type postListConnector struct {
	calls *[]listQueryCall
	state *driverState
}
type postListConn struct {
	*testConn
	calls *[]listQueryCall
}

func (c postListConnector) Connect(context.Context) (driver.Conn, error) {
	return &postListConn{&testConn{c.state}, c.calls}, nil
}
func (c postListConnector) Driver() driver.Driver { return testDriver{} }
func (c *postListConn) QueryContext(_ context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	*c.calls = append(*c.calls, listQueryCall{query, append([]driver.NamedValue(nil), args...)})
	if strings.HasPrefix(query, "SELECT COUNT(*)") {
		return &alertRows{values: []driver.Value{int64(3)}}, nil
	}
	at := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	return &alertRows{values: []driver.Value{int64(1), int64(7), "synthetic post", "original", "public", "zh", nil, nil, nil, nil, int64(2), int64(3), int64(1), int64(0), int64(10), float64(12.5), int64(0), int64(0), at, at, int64(1)}}, nil
}
func TestPostListRepositoryUsesMatchingFiltersAndBinds(t *testing.T) {
	var calls []listQueryCall
	db := sql.OpenDB(postListConnector{&calls, &driverState{}})
	defer db.Close()
	repo := OracleSessions{db}
	query := parsePostListQuery("timeline=following&q=%20%23%23Cat_%25%20&sort=popular&page=2&page_size=1")
	viewer := int64(42)
	items, total, err := repo.ListVisiblePosts(context.Background(), &viewer, query)
	if err != nil || total != 3 || len(items) != 1 || items[0].PostID != 1 || items[0].Stats.EngagementScore != 12.5 {
		t.Fatalf("items=%#v total=%d err=%v", items, total, err)
	}
	if len(calls) != 2 {
		t.Fatal("expected count and page queries", calls)
	}
	for _, call := range calls {
		for _, required := range []string{"fn_can_view_post(:viewer_id,v.post_id)=1", "f.status='active'", "t.name_lower LIKE :tag_q"} {
			if !strings.Contains(call.sql, required) {
				t.Fatalf("missing %s in %s", required, call.sql)
			}
		}
		if strings.Contains(call.sql, "cat_%") {
			t.Fatal("search interpolated into SQL")
		}
		if len(call.args) < 3 || call.args[0].Value != int64(42) || call.args[1].Value != "%##cat_%%" || call.args[2].Value != "%cat_%%" {
			t.Fatal("incorrect binds", call.args)
		}
	}
	if !strings.Contains(calls[1].sql, "ROW_NUMBER() OVER (ORDER BY v.engagement_score DESC,v.created_at DESC)") || len(calls[1].args) != 5 || calls[1].args[3].Value != float64(2) || calls[1].args[4].Value != float64(2) {
		t.Fatal("incorrect page", calls[1])
	}
}

func TestPostListModeSQLIsScopedAndSorted(t *testing.T) {
	viewer := int64(42)
	for _, tc := range []struct{ mode, sort, filter, order string }{
		{"me", "newest", "v.author_id=:viewer_id", "v.created_at DESC"},
		{"bookmarks", "newest", "FROM n_post_bookmarks b", "v.created_at DESC"},
		{"likes", "oldest", "FROM n_post_likes l", "l.user_id=:viewer_id) ASC"},
		{"likes", "newest", "FROM n_post_likes l", "l.user_id=:viewer_id) DESC"},
		{"likes", "popular", "FROM n_post_likes l", "v.engagement_score DESC,v.created_at DESC"},
	} {
		query := parsePostListQuery("timeline=mentions&q=cat")
		query.Mode, query.Sort = tc.mode, tc.sort
		count, rows, args, _ := postListSQL(&viewer, query)
		if !strings.Contains(count, tc.filter) || !strings.Contains(rows, tc.order) || !strings.Contains(count, "pm.mentioned_user_id=:viewer_id") || !strings.Contains(count, "t.name_lower LIKE :tag_q") || args[0].(sql.NamedArg).Value != viewer {
			t.Fatalf("mode %s: %s %s %#v", tc.mode, count, rows, args)
		}
	}
}
