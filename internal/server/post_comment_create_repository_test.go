package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"strings"
	"testing"
	"time"
)

type createCommentState struct {
	driverState
	hidden, parentMissing, loseVisibility, loseParent, failRead, muted bool
	visibilityChecks                                                   int
	writes                                                             []listQueryCall
	queries                                                            []listQueryCall
}
type createCommentConnector struct{ state *createCommentState }
type createCommentConn struct {
	*testConn
	owner *createCommentState
}

func (c createCommentConnector) Connect(context.Context) (driver.Conn, error) {
	return &createCommentConn{&testConn{&c.state.driverState}, c.state}, nil
}
func (c createCommentConnector) Driver() driver.Driver { return testDriver{} }
func (c *createCommentConn) QueryContext(_ context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	c.owner.queries = append(c.owner.queries, listQueryCall{q, append([]driver.NamedValue(nil), args...)})
	if q == publishPolicy.SQL["lock"] {
		return &alertRows{values: []driver.Value{int64(42)}}, nil
	}
	if q == publishPolicy.SQL["allowed"] {
		allowed := int64(1)
		if c.owner.muted {
			allowed = 0
		}
		return &alertRows{values: []driver.Value{allowed}}, nil
	}
	switch {
	case strings.Contains(q, "FROM n_posts p"):
		c.owner.visibilityChecks++
		if c.owner.hidden || (c.owner.loseVisibility && c.owner.visibilityChecks > 1) {
			return emptyRows{&c.owner.driverState}, nil
		}
		return &alertRows{values: []driver.Value{int64(1)}}, nil
	case strings.Contains(q, "seq_comment_id.NEXTVAL"):
		return &alertRows{values: []driver.Value{int64(100)}}, nil
	case strings.Contains(q, "NVL(c.root_comment_id"):
		if c.owner.parentMissing {
			return emptyRows{&c.owner.driverState}, nil
		}
		return &alertRows{values: []driver.Value{int64(30)}}, nil
	case strings.Contains(q, "FROM v_post_comment_list_item"):
		if c.owner.failRead {
			return nil, errors.New("private read failure")
		}
		at := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
		var parent, root driver.Value = nil, int64(100)
		if len(c.owner.writes) > 0 {
			for _, a := range c.owner.writes[0].args {
				if a.Name == "parent_comment_id" {
					parent = a.Value
				}
				if a.Name == "root_comment_id" {
					root = a.Value
				}
			}
		}
		return &alertRows{values: []driver.Value{int64(100), int64(1), int64(42), parent, root, "hello", at, at, int64(0), int64(0), int64(0)}}, nil
	default:
		return nil, errors.New("unexpected query")
	}
}
func (c *createCommentConn) ExecContext(_ context.Context, q string, args []driver.NamedValue) (driver.Result, error) {
	c.owner.writes = append(c.owner.writes, listQueryCall{q, append([]driver.NamedValue(nil), args...)})
	if c.owner.loseVisibility || c.owner.loseParent {
		return driver.RowsAffected(0), nil
	}
	return driver.RowsAffected(1), nil
}

func TestCreatePostCommentRepository(t *testing.T) {
	parent := int64(40)
	for _, tc := range []struct {
		name            string
		state           createCommentState
		parent          *int64
		want            error
		writes, commits int
		root            int64
	}{
		{"muted", createCommentState{muted: true}, nil, errPublishForbidden, 0, 0, 0},
		{"hidden", createCommentState{hidden: true}, nil, errCommentPostUnavailable, 0, 0, 0},
		{"missing parent", createCommentState{parentMissing: true}, &parent, errCommentParentUnavailable, 0, 0, 0},
		{"visibility race", createCommentState{loseVisibility: true}, nil, errCommentPostUnavailable, 1, 1, 0},
		{"parent race", createCommentState{loseParent: true}, &parent, errCommentParentUnavailable, 1, 1, 0},
		{"read after commit fails", createCommentState{failRead: true}, nil, errSessionStore, 1, 1, 0},
		{"root", createCommentState{}, nil, nil, 1, 1, 100},
		{"reply", createCommentState{}, &parent, nil, 1, 1, 30},
	} {
		t.Run(tc.name, func(t *testing.T) {
			db := sql.OpenDB(createCommentConnector{&tc.state})
			defer db.Close()
			result, err := (OracleSessions{db}).CreatePostComment(context.Background(), 42, 1, "hello", tc.parent)
			if !errors.Is(err, tc.want) || len(tc.state.writes) != tc.writes || tc.state.commits != tc.commits {
				t.Fatalf("result=%+v err=%v writes=%d commits=%d", result, err, len(tc.state.writes), tc.state.commits)
			}
			if tc.state.muted && tc.state.rollbacks != 1 {
				t.Fatal("expected rollback", tc.state.rollbacks)
			}
			if tc.want == nil && (result.ID != 100 || result.AuthorID != 42 || result.RootID == nil || *result.RootID != tc.root || result.Content != "hello") {
				t.Fatal(result)
			}
			if len(tc.state.writes) > 0 {
				write := tc.state.writes[0]
				assertCommentLikeScope(t, write.sql)
				for _, fragment := range []string{"fn_can_view_post(:viewer_id,:post_id)=1", "c.comment_id=:parent_comment_id", "c.post_id=:post_id"} {
					if !strings.Contains(write.sql, fragment) {
						t.Fatal(write.sql)
					}
				}
				binds := map[string]any{}
				for _, arg := range write.args {
					binds[arg.Name] = arg.Value
				}
				if binds["viewer_id"] != int64(42) || binds["post_id"] != int64(1) || binds["comment_id"] != int64(100) {
					t.Fatal(binds)
				}
			}
			for _, query := range tc.state.queries {
				if strings.Contains(query.sql, "NVL(c.root_comment_id") {
					assertCommentLikeScope(t, query.sql)
				}
				if strings.Contains(query.sql, "FROM v_post_comment_list_item") && (!strings.Contains(query.sql, "c.user_id=:viewer_id") || !strings.Contains(query.sql, "fn_can_view_post(:viewer_id,c.post_id)=1")) {
					t.Fatal(query.sql)
				}
			}
		})
	}
}
