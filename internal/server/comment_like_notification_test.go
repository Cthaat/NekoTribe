package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"strings"
	"testing"
)

type likeNoticeState struct {
	alertState
	author  int64
	missing bool
}
type likeNoticeConnector struct{ s *likeNoticeState }
type likeNoticeConn struct {
	*alertConn
	s *likeNoticeState
}

func (c likeNoticeConnector) Connect(context.Context) (driver.Conn, error) {
	return &likeNoticeConn{&alertConn{testConn: &testConn{state: &c.s.driverState}, state: &c.s.alertState}, c.s}, nil
}
func (c likeNoticeConnector) Driver() driver.Driver { return testDriver{} }
func (c *likeNoticeConn) QueryContext(ctx context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	switch {
	case strings.Contains(q, "FROM n_comments WHERE"):
		if c.s.missing {
			return emptyRows{&c.s.driverState}, nil
		}
		return &alertRows{values: []driver.Value{c.s.author, int64(9), "  comment\ntext "}}, nil
	case strings.Contains(q, "COALESCE(display_name"):
		return &alertRows{values: []driver.Value{"viewer"}}, nil
	case strings.Contains(q, "FROM n_posts WHERE"):
		return &alertRows{values: []driver.Value{" post  text "}}, nil
	default:
		return c.alertConn.QueryContext(ctx, q, args)
	}
}
func TestPrepareCommentLikeNotification(t *testing.T) {
	for _, tc := range []struct {
		name                  string
		author, push, enabled int64
		missing, stored       bool
	}{{"normal", 7, 1, 1, false, true}, {"push disabled", 7, 0, 1, false, true}, {"type disabled", 7, 1, 0, false, false}, {"self", 42, 1, 1, false, false}, {"missing", 7, 1, 1, true, false}} {
		t.Run(tc.name, func(t *testing.T) {
			s := &likeNoticeState{alertState: alertState{push: tc.push, enabled: tc.enabled}, author: tc.author, missing: tc.missing}
			db := sql.OpenDB(likeNoticeConnector{s})
			defer db.Close()
			recipient, stored, err := (OracleSessions{db}).PrepareCommentLikeNotification(context.Background(), 42, 20)
			if err != nil || (stored != nil) != tc.stored {
				t.Fatal(recipient, stored, err)
			}
			if tc.stored {
				if recipient != 7 || stored.PushEnabled != (tc.push == 1) || s.commits != 1 {
					t.Fatal(recipient, stored, s.commits)
				}
				values := map[string]any{}
				for _, a := range s.args {
					values[a.Name] = a.Value
				}
				metadata, _ := values["metadata_json"].(string)
				for _, part := range []string{`"post_id":9`, `"target_post_id":9`, `"comment_id":20`, `"comment_excerpt":"comment text"`, `"post_excerpt":"post text"`, `"event":"comment_like"`} {
					if !strings.Contains(metadata, part) {
						t.Fatal(metadata)
					}
				}
				if values["resource_type"] != "comment" || values["resource_id"] != int64(20) || values["user_id"] != int64(7) {
					t.Fatal(values)
				}
			}
		})
	}
}
