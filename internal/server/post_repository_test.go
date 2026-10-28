package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"strings"
	"testing"
	"time"
)

type postRepoConnector struct{ state *driverState }
type postRepoConn struct{ *testConn }

func (c postRepoConnector) Connect(context.Context) (driver.Conn, error) {
	return &postRepoConn{&testConn{c.state}}, nil
}
func (c postRepoConnector) Driver() driver.Driver { return testDriver{} }
func (c *postRepoConn) QueryContext(_ context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	c.state.sql = q
	c.state.args = args
	at := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	switch {
	case strings.Contains(q, "FROM v_post_feed_item"):
		return &alertRows{values: []driver.Value{int64(1), int64(7), "synthetic post", "original", "public", "zh", nil, nil, nil, nil, int64(2), int64(3), int64(1), int64(0), int64(10), float64(12.5), int64(0), int64(0), at, at}}, nil
	case strings.Contains(q, "FROM v_user_profile_public u LEFT"):
		return &alertRows{values: []driver.Value{int64(7), "publicuser", nil, "Public User", "hello", nil, nil, int64(0), int64(2), int64(3), int64(4), int64(5), "hidden", at, "following"}}, nil
	case strings.Contains(q, "FROM n_post_media"):
		return &alertRows{values: []driver.Value{int64(17), "image", "photo.png", "/storage/post/photo.png", int64(1234), "image/png", int64(800), int64(600), nil, "/storage/post/thumb.png", "a photo", "description", "ready", at}}, nil
	case strings.Contains(q, "FROM n_post_tags"):
		return &alertRows{values: []driver.Value{"cat"}}, nil
	case strings.Contains(q, "FROM n_post_mentions"):
		return &alertRows{values: []driver.Value{int64(8), "mentioned", nil, "Mentioned User", nil, nil, nil, int64(0), int64(0), int64(0), int64(0), int64(0), nil}}, nil
	}
	return nil, errSessionStore
}
func TestPostRepositorySQLMappingAndViewerBindings(t *testing.T) {
	s := &driverState{}
	db := sql.OpenDB(postRepoConnector{s})
	defer db.Close()
	repo := OracleSessions{db}
	ctx := context.Background()
	p, found, err := repo.ReadVisiblePost(ctx, nil, 1)
	if err != nil || !found || p.PostID != 1 || p.Author.UserID != 7 || p.Stats.ViewsCount != 10 || p.Stats.EngagementScore != 12.5 {
		t.Fatalf("post %#v %v", p, err)
	}
	if !strings.Contains(s.sql, "fn_can_view_post(:viewer_id,v.post_id)=1") || len(s.args) != 2 || s.args[0].Name != "viewer_id" || s.args[0].Value != nil || s.args[1].Value != int64(1) {
		t.Fatal("visibility or NULL viewer binds", s.sql, s.args)
	}
	a, found, err := repo.ReadPostAuthor(ctx, nil, 7)
	if err != nil || !found || a.OnlineStatus != "hidden" || a.LastSeenAt != nil || s.args[0].Value != nil {
		t.Fatal("author mapping", err)
	}
	media, err := repo.ReadPostMedia(ctx, 1)
	if err != nil || len(media) != 1 || media[0].Width == nil || *media[0].Width != 800 || media[0].Duration != nil || !strings.Contains(s.sql, "ORDER BY pm.sort_order") {
		t.Fatal("media mapping", err)
	}
	tags, err := repo.ReadPostTags(ctx, 1)
	if err != nil || len(tags) != 1 || tags[0] != "cat" || !strings.Contains(s.sql, "ORDER BY t.name") {
		t.Fatal("tags", err)
	}
	mentions, err := repo.ReadPostMentions(ctx, nil, 1)
	if err != nil || len(mentions) != 1 || mentions[0].OnlineStatus != "offline" || mentions[0].LastSeenAt != nil || s.args[0].Value != nil || !strings.Contains(s.sql, "ORDER BY u.username") {
		t.Fatal("mentions", err)
	}
	if err = repo.IncrementPostViews(ctx, 1); err != nil || s.commits != 1 || !strings.Contains(s.sql, "views_count=views_count+1") {
		t.Fatal("view increment", err)
	}
}
