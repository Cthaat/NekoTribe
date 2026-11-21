package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"net/http/httptest"
	"strings"
	"testing"
)

type postWriteFixture struct {
	state                 driverState
	group, post, moderate bool
	failWrite             bool
	failReadback          bool
	comment               bool
	accountMuted          bool
	hiddenAuthor          int64
	hideAfterWrite        bool
	commentAuthor         int64
	writes                int
}

type postWriteConn struct {
	*testConn
	fixture *postWriteFixture
}

func (*postWriteFixture) Driver() driver.Driver { return testDriver{} }

func (f *postWriteFixture) Connect(context.Context) (driver.Conn, error) {
	return &postWriteConn{&testConn{&f.state}, f}, nil
}

func (c *postWriteConn) QueryContext(_ context.Context, stmt string, args []driver.NamedValue) (driver.Rows, error) {
	row := func(value int64, missing bool) driver.Rows {
		return &alertRows{values: []driver.Value{value}, done: missing}
	}
	switch stmt {
	case publishPolicy.SQL["lock"]:
		return row(42, false), nil
	case publishPolicy.SQL["allowed"]:
		if c.fixture.accountMuted {
			return row(0, false), nil
		}
		return row(1, false), nil
	case lockGroupContentSQL:
		return row(7, !c.fixture.group), nil
	case canViewGroupContentSQL, canPostGroupContentSQL, canCommentGroupContentSQL:
		return row(1, false), nil
	case groupPostAuthorSQL:
		return row(21, !c.fixture.post), nil
	case "SELECT seq_group_post_id.NEXTVAL AS id FROM dual":
		return row(5, false), nil
	case groupCommentAuthorSQL:
		if c.fixture.commentAuthor != 0 {
			return row(c.fixture.commentAuthor, !c.fixture.comment), nil
		}
		return row(21, !c.fixture.comment), nil
	case groupAuthorVisibleSQL:
		var author int64
		for _, arg := range args {
			if arg.Name == "author_id" {
				author, _ = arg.Value.(int64)
			}
		}
		return row(1, author == c.fixture.hiddenAuthor && (!c.fixture.hideAfterWrite || c.fixture.writes > 0)), nil
	case "SELECT seq_group_comment_id.NEXTVAL AS id FROM dual":
		return row(6, false), nil
	case readCreatedGroupCommentSQL:
		if c.fixture.failReadback {
			return nil, errors.New("readback failed")
		}
		return &alertRows{values: []driver.Value{
			int64(6), int64(5), int64(42), int64(4), int64(21), "reply", int64(0), nil, nil, int64(0), int64(1),
		}}, nil
	case groupContentPostsSQL:
		if c.fixture.failReadback {
			return nil, errors.New("readback failed")
		}
		return &alertRows{values: []driver.Value{
			int64(1), int64(1), int64(5), int64(7), int64(42), "test", nil,
			int64(0), int64(1), int64(0), int64(0), int64(0), nil, nil, int64(0),
		}}, nil
	case publicProfileSQL:
		return &alertRows{values: []driver.Value{int64(42), "owner", nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, "offline", nil, "self"}}, nil
	case canModerateGroupContentSQL:
		if c.fixture.moderate {
			return row(1, false), nil
		}
		return row(0, false), nil
	case "SELECT likes_count FROM n_group_posts WHERE post_id=:post_id", "SELECT likes_count FROM n_group_comments WHERE comment_id=:comment_id":
		return row(3, false), nil
	default:
		return nil, errors.New("unexpected query")
	}
}

func TestGroupCommentWritesCheckVisibilityAndRollback(t *testing.T) {
	parent := int64(4)
	for _, tc := range []struct {
		name, action string
		hidden       int64
		late, admin  bool
		writes       int
		missing      string
	}{
		{"hidden post", "create", 21, false, false, 0, "群组帖子不存在"},
		{"hidden parent", "create", 23, false, false, 0, "群组评论不存在"},
		{"blocked after insert", "create", 23, true, false, 1, "群组评论不存在"},
		{"hidden like target", "like", 23, false, false, 0, "群组评论不存在"},
		{"hidden unlike target", "unlike", 23, false, false, 0, "群组评论不存在"},
		{"blocked after like", "like", 23, true, false, 1, "群组评论不存在"},
		{"blocked after unlike", "unlike", 23, true, false, 1, "群组评论不存在"},
		{"moderator can remove hidden content", "delete", 23, false, true, 1, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := &postWriteFixture{
				group: true, post: true, comment: true, commentAuthor: 23,
				hiddenAuthor: tc.hidden, hideAfterWrite: tc.late, moderate: tc.admin,
			}
			db := sql.OpenDB(f)
			defer db.Close()
			input := groupCommentMutation{group: 7, post: 5, comment: 4, action: tc.action, content: "reply", parent: &parent}
			_, err := (OracleSessions{DB: db}).WriteGroupComment(context.Background(), 42, input, StorageURLPolicy{})
			if tc.missing == "" {
				if err != nil || f.state.commits != 1 {
					t.Fatalf("expected commit, state=%+v err=%v", f.state, err)
				}
			} else {
				var failure *groupMembershipFailure
				if !errors.As(err, &failure) || failure.status != 404 || failure.message != tc.missing || f.state.commits != 0 || f.state.rollbacks != 1 {
					t.Fatalf("expected rollback and 404 for %q, state=%+v err=%v", tc.missing, f.state, err)
				}
			}
			if f.writes != tc.writes {
				t.Fatalf("writes=%d want=%d", f.writes, tc.writes)
			}
		})
	}
}

func TestGroupPublishingDeniesMutedAccountBeforeWriting(t *testing.T) {
	f := &postWriteFixture{group: true, post: true, accountMuted: true, moderate: true}
	db := sql.OpenDB(f)
	defer db.Close()
	store := OracleSessions{DB: db}
	ctx := context.Background()
	_, postErr := store.WriteGroupPost(ctx, 42, groupPostMutation{group: 7, action: "create", content: "post", announcement: true}, StorageURLPolicy{})
	_, commentErr := store.WriteGroupComment(ctx, 42, groupCommentMutation{group: 7, post: 5, action: "create", content: "comment"}, StorageURLPolicy{})
	if !errors.Is(postErr, errPublishForbidden) || !errors.Is(commentErr, errPublishForbidden) || f.writes != 0 || f.state.commits != 0 || f.state.rollbacks != 2 {
		t.Fatalf("post=%v comment=%v writes=%d state=%+v", postErr, commentErr, f.writes, f.state)
	}
}

func TestGroupCommentReplyCreation(t *testing.T) {
	parent, wrong := int64(4), int64(9)
	for _, tc := range []struct {
		name               string
		comment, readError bool
		reply              *int64
		status, writes     int
	}{
		{"success", true, false, nil, 200, 1},
		{"cross-post parent", false, false, nil, 404, 0},
		{"wrong reply target", true, false, &wrong, 422, 0},
		{"readback failure", true, true, nil, 500, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := &postWriteFixture{group: true, post: true, comment: tc.comment, failReadback: tc.readError}
			db := sql.OpenDB(f)
			defer db.Close()
			value, err := (OracleSessions{DB: db}).WriteGroupComment(context.Background(), 42, groupCommentMutation{
				group: 7, post: 5, action: "create", content: "reply", parent: &parent, reply: tc.reply,
			}, StorageURLPolicy{})
			status, commits := 200, 0
			var failure *groupMembershipFailure
			if errors.As(err, &failure) {
				status = failure.status
			} else if err != nil {
				status = 500
			} else {
				commits = 1
				comment := value.(groupComment)
				if comment.ID != 6 || comment.Parent == nil || *comment.Parent != parent || comment.ReplyTo == nil || !comment.CanDelete {
					t.Fatalf("comment=%+v", comment)
				}
			}
			if status != tc.status || f.writes != tc.writes || f.state.commits != commits || f.state.rollbacks != 1-commits {
				t.Fatalf("status=%d writes=%d state=%+v error=%v", status, f.writes, f.state, err)
			}
		})
	}
}

func (c *postWriteConn) ExecContext(_ context.Context, stmt string, _ []driver.NamedValue) (driver.Result, error) {
	c.fixture.writes++
	if c.fixture.failWrite {
		return nil, errors.New("failed write")
	}
	if stmt == likeGroupPostSQL || stmt == unlikeGroupPostSQL {
		return driver.RowsAffected(0), nil
	}
	return driver.RowsAffected(1), nil
}

func TestGroupPostWritesAreScopedAndAtomic(t *testing.T) {
	for _, tc := range []struct {
		name                    string
		action                  string
		group, post, moderator  bool
		writeFailure            bool
		status, writes, commits int
	}{
		{"moderator pin", "pin", true, true, true, false, 200, 1, 1},
		{"dissolved", "pin", false, true, true, false, 404, 0, 0},
		{"wrong group", "like", true, false, false, false, 404, 0, 0},
		{"member delete", "delete", true, true, false, false, 422, 0, 0},
		{"member announcement", "create", true, true, false, false, 422, 0, 0},
		{"repeat like", "like", true, true, false, false, 200, 1, 1},
		{"repeat unlike", "unlike", true, true, false, false, 200, 1, 1},
		{"write fails", "pin", true, true, true, true, 500, 1, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := &postWriteFixture{group: tc.group, post: tc.post, moderate: tc.moderator, failWrite: tc.writeFailure}
			db := sql.OpenDB(f)
			defer db.Close()
			data, err := (OracleSessions{DB: db}).WriteGroupPost(context.Background(), 42, groupPostMutation{action: tc.action, group: 7, post: 5, pin: true, announcement: true}, StorageURLPolicy{})
			status := 200
			var failure *groupMembershipFailure
			switch {
			case errors.As(err, &failure):
				status = failure.status
			case errors.Is(err, errGroupDetailMissing):
				status = 404
			case err != nil:
				status = 500
			}
			if status != tc.status || f.writes != tc.writes || f.state.commits != tc.commits || f.state.rollbacks != 1-tc.commits {
				t.Fatalf("status=%d writes=%d state=%+v err=%v", status, f.writes, f.state, err)
			}
			if tc.status == 200 && (tc.action == "like" || tc.action == "unlike") {
				got := data.(map[string]any)
				if got["likes_count"] != int64(3) || got["is_liked"] != (tc.action == "like") {
					t.Fatalf("reaction=%v", got)
				}
			}
		})
	}
}

func TestGroupPostMutationsCheckAuthorVisibility(t *testing.T) {
	for _, tc := range []struct {
		name, action string
		pin, late    bool
		writes       int
		missing      bool
	}{
		{"hidden post like", "like", false, false, 0, true},
		{"hidden post unlike", "unlike", false, false, 0, true},
		{"hidden post pin", "pin", true, false, 0, true},
		{"blocked after like", "like", false, true, 1, true},
		{"blocked after unlike", "unlike", false, true, 1, true},
		{"blocked after pin", "pin", true, true, 1, true},
		{"moderator can unpin hidden post", "pin", false, false, 1, false},
		{"moderator can remove hidden post", "delete", false, false, 1, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := &postWriteFixture{group: true, post: true, moderate: true, hiddenAuthor: 21, hideAfterWrite: tc.late}
			db := sql.OpenDB(f)
			defer db.Close()
			_, err := (OracleSessions{DB: db}).WriteGroupPost(context.Background(), 42,
				groupPostMutation{group: 7, post: 5, action: tc.action, pin: tc.pin}, StorageURLPolicy{})
			if tc.missing {
				var failure *groupMembershipFailure
				if !errors.As(err, &failure) || failure.status != 404 || f.state.commits != 0 || f.state.rollbacks != 1 {
					t.Fatalf("expected rollback and 404, state=%+v err=%v", f.state, err)
				}
			} else if err != nil || f.state.commits != 1 {
				t.Fatalf("expected commit, state=%+v err=%v", f.state, err)
			}
			if f.writes != tc.writes {
				t.Fatalf("writes=%d want=%d", f.writes, tc.writes)
			}
		})
	}
}

func TestGroupPostWriteRouteValidatesBody(t *testing.T) {
	codec, tokens := fixture(t)
	app := NewHandler(codec, store(), CorsPolicy{})
	for _, tc := range []struct {
		method, path, body, message string
	}{
		{"POST", "", `{"content":"   "}`, "content 参数错误"},
		{"POST", "", `{"content":"OK","media_urls":["a,b"]}`, "media_urls 参数错误"},
		{"PUT", "/7/pin-status", `{"is_pinned":1}`, "is_pinned 参数错误"},
		{"DELETE", "/7", "{", "请求体必须是 JSON 对象"},
	} {
		req := httptest.NewRequest(tc.method, "/api/v2/groups/42/posts"+tc.path, strings.NewReader(tc.body))
		req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		w := httptest.NewRecorder()
		app.ServeHTTP(w, req)
		if w.Code != 400 || !strings.Contains(w.Body.String(), tc.message) || w.Header().Get("Cache-Control") != "private, no-store" {
			t.Fatalf("%s %s: %d %s", tc.method, tc.path, w.Code, w.Body)
		}
	}
}

func TestGroupPostCreationReadsBeforeCommit(t *testing.T) {
	for _, failReadback := range []bool{false, true} {
		f := &postWriteFixture{group: true, moderate: true, failReadback: failReadback}
		db := sql.OpenDB(f)
		input := groupPostMutation{action: "create", group: 7, content: "test", announcement: true}
		data, err := (OracleSessions{DB: db}).WriteGroupPost(context.Background(), 42, input, StorageURLPolicy{})
		db.Close()
		if failReadback {
			if err == nil || f.state.rollbacks != 1 || f.state.commits != 0 {
				t.Fatalf("err=%v state=%+v", err, f.state)
			}
		} else {
			post, ok := data.(groupPost)
			if err != nil || f.state.commits != 1 || !ok || post.ID != 5 || !post.Announcement || post.Author.UserID != 42 {
				t.Fatalf("data=%v err=%v state=%+v", data, err, f.state)
			}
		}
	}
}
