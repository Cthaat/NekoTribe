package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"strings"
	"testing"
)

type commentNoticeState struct {
	driverState
	calls         []listQueryCall
	parentAuthor  int64
	missingParent bool
	failure       string
}
type commentNoticeConnector struct{ state *commentNoticeState }
type commentNoticeConn struct {
	*testConn
	owner *commentNoticeState
}

func (c commentNoticeConnector) Connect(context.Context) (driver.Conn, error) {
	return &commentNoticeConn{&testConn{&c.state.driverState}, c.state}, nil
}
func (c commentNoticeConnector) Driver() driver.Driver { return testDriver{} }
func (c *commentNoticeConn) QueryContext(_ context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	c.owner.calls = append(c.owner.calls, listQueryCall{q, append([]driver.NamedValue(nil), args...)})
	if c.owner.failure != "" && strings.Contains(q, c.owner.failure) {
		return nil, errors.New("private database error")
	}
	switch {
	case strings.Contains(q, "COALESCE(display_name"):
		return &alertRows{values: []driver.Value{"viewer"}}, nil
	case strings.HasPrefix(q, "SELECT author_id FROM n_posts"):
		return &alertRows{values: []driver.Value{int64(7)}}, nil
	case strings.HasPrefix(q, "SELECT user_id FROM n_comments"):
		if c.owner.missingParent {
			return emptyRows{&c.owner.driverState}, nil
		}
		return &alertRows{values: []driver.Value{c.owner.parentAuthor}}, nil
	case strings.Contains(q, "FROM n_comments WHERE"):
		text := "  first\ncomment  "
		if len(args) > 0 && args[0].Value == int64(40) {
			text = " parent "
		}
		return &alertRows{values: []driver.Value{int64(42), int64(1), text}}, nil
	case strings.Contains(q, "FROM n_posts WHERE"):
		return &alertRows{values: []driver.Value{" original\t post "}}, nil
	default:
		return nil, errors.New("unexpected query")
	}
}
func TestCommentNoticeRepositoryScopesAndMapsExcerpts(t *testing.T) {
	state := &commentNoticeState{parentAuthor: 8}
	db := sql.OpenDB(commentNoticeConnector{state})
	defer db.Close()
	repo := OracleSessions{db}
	notice, err := repo.CommentNoticeContext(context.Background(), 42, 1, 100)
	if err != nil || notice.ActorName != "viewer" || notice.PostAuthor != 7 || string(notice.CommentExcerpt) != `"first comment"` || string(notice.PostExcerpt) != `"original post"` {
		t.Fatal(notice, err)
	}
	if len(state.calls) != 4 {
		t.Fatal(state.calls)
	}
	parent, err := repo.CommentParentNotice(context.Background(), 40, 7)
	if err != nil || parent.Author != 8 || string(parent.Excerpt) != `"parent"` || len(state.calls) != 6 {
		t.Fatal(parent, err, state.calls)
	}
	for _, call := range state.calls {
		if len(call.args) != 1 {
			t.Fatal(call)
		}
		if strings.Contains(call.sql, "FROM n_comments") && call.args[0].Name != "comment_id" {
			t.Fatal(call)
		}
	}
	state.calls = nil
	state.parentAuthor = 7
	parent, err = repo.CommentParentNotice(context.Background(), 40, 7)
	if err != nil || parent.Author != 7 || len(state.calls) != 1 {
		t.Fatal(parent, err, state.calls)
	}
	state.calls = nil
	state.missingParent = true
	parent, err = repo.CommentParentNotice(context.Background(), 40, 7)
	if err != nil || parent.Author != 0 || len(state.calls) != 1 {
		t.Fatal(parent, err, state.calls)
	}
	state.failure = "FROM n_posts"
	if _, err = repo.CommentNoticeContext(context.Background(), 42, 1, 100); err == nil {
		t.Fatal("expected sanitized failure")
	}
}
