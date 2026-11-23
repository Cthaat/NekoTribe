package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"strings"
	"testing"
)

type createPostState struct {
	driverState
	hidden, race, badMedia, muted bool
	failAt                        string
	calls                         []listQueryCall
	mediaKeys                     map[float64]string
	privateDenied                 bool
}
type createPostConnector struct{ s *createPostState }
type createPostConn struct {
	*testConn
	s *createPostState
}
type createPostTx struct{ s *createPostState }

func (c *createPostConn) Begin() (driver.Tx, error) { return &createPostTx{c.s}, nil }
func (tx *createPostTx) Commit() error {
	tx.s.commits++
	if tx.s.fail == "commit" {
		return errors.New("private commit failure")
	}
	return nil
}
func (tx *createPostTx) Rollback() error {
	tx.s.rollbacks++
	if tx.s.fail == "rollback" {
		return errors.New("private rollback failure")
	}
	return nil
}

func (c createPostConnector) Connect(context.Context) (driver.Conn, error) {
	return &createPostConn{&testConn{&c.s.driverState}, c.s}, nil
}
func (c createPostConnector) Driver() driver.Driver { return testDriver{} }
func (c *createPostConn) QueryContext(_ context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	c.s.calls = append(c.s.calls, listQueryCall{q, append([]driver.NamedValue(nil), args...)})
	if q == publishPolicy.SQL["lock"] {
		return &alertRows{values: []driver.Value{int64(42)}}, nil
	}
	if q == publishPolicy.SQL["allowed"] {
		allowed := int64(1)
		if c.s.muted {
			allowed = 0
		}
		return &alertRows{values: []driver.Value{allowed}}, nil
	}
	if strings.Contains(q, "seq_post_id.NEXTVAL") {
		return &alertRows{values: []driver.Value{int64(100)}}, nil
	}
	if q == lockPostMediaSQL {
		id := args[0].Value.(float64)
		return &alertRows{values: []driver.Value{int64(id), c.s.mediaKeys[id]}}, nil
	}
	if q == directExtrasContract.SQL["asset_is_linked"] {
		return emptyRows{&c.s.driverState}, nil
	}
	if q == privateMediaBinding.Post {
		if c.s.privateDenied {
			return emptyRows{&c.s.driverState}, nil
		}
		return &alertRows{values: []driver.Value{int64(1)}}, nil
	}
	if strings.Contains(q, "FROM n_posts p") {
		if c.s.hidden {
			return emptyRows{&c.s.driverState}, nil
		}
		return &alertRows{values: []driver.Value{int64(1)}}, nil
	}
	return nil, errors.New("unexpected query")
}
func (c *createPostConn) ExecContext(_ context.Context, q string, args []driver.NamedValue) (driver.Result, error) {
	c.s.calls = append(c.s.calls, listQueryCall{q, append([]driver.NamedValue(nil), args...)})
	if c.s.failAt != "" && strings.Contains(q, c.s.failAt) {
		return nil, errors.New("private error")
	}
	if (strings.HasPrefix(q, "INSERT INTO n_posts") && c.s.race) || (strings.HasPrefix(q, "INSERT INTO n_post_media") && c.s.badMedia) {
		return driver.RowsAffected(0), nil
	}
	return driver.RowsAffected(1), nil
}
func TestCreatePostAtomic(t *testing.T) {
	ref := int64(1)
	input := PostCreateInput{Content: "hello", Visibility: "public", ReplyToPostID: &ref, MediaIDs: []float64{11, 11, 12}, Tags: []string{"#cat", "cat"}, Mentions: []float64{7, 7}}
	for _, tc := range []struct {
		name               string
		s                  createPostState
		want               error
		commits, rollbacks int
	}{{"hidden", createPostState{hidden: true}, errPostReferenceUnavailable, 0, 0}, {"muted", createPostState{muted: true}, errPublishForbidden, 0, 1}, {"race", createPostState{race: true}, errPostReferenceUnavailable, 0, 1}, {"bad media", createPostState{badMedia: true}, errPostMediaUnavailable, 0, 1}, {"tag failure", createPostState{failAt: "INSERT INTO n_post_tags"}, errSessionStore, 0, 1}, {"mention failure", createPostState{failAt: "INSERT INTO n_post_mentions"}, errSessionStore, 0, 1}, {"commit failure", createPostState{driverState: driverState{fail: "commit"}}, errSessionStore, 1, 0}, {"success", createPostState{}, nil, 1, 0}} {
		t.Run(tc.name, func(t *testing.T) {
			db := sql.OpenDB(createPostConnector{&tc.s})
			defer db.Close()
			id, err := (OracleSessions{db}).CreatePostAtomic(context.Background(), 42, input)
			if !errors.Is(err, tc.want) || tc.s.commits != tc.commits || tc.s.rollbacks != tc.rollbacks {
				t.Fatal(id, err, tc.s.commits, tc.s.rollbacks)
			}
			if err == nil && id != 100 {
				t.Fatal(id)
			}
			if tc.s.muted {
				for _, call := range tc.s.calls {
					if !strings.HasPrefix(call.sql, "SELECT ") {
						t.Fatal("write after moderation denial", call.sql)
					}
				}
			}
			var media, tags, mentions int
			for _, call := range tc.s.calls {
				if strings.HasPrefix(call.sql, "INSERT INTO n_posts") {
					for _, fragment := range []string{"fn_can_view_post(:author_id,p.post_id)=1", "p.is_deleted=0"} {
						if !strings.Contains(call.sql, fragment) {
							t.Fatal(call.sql)
						}
					}
					bindings := map[string]any{}
					for _, a := range call.args {
						bindings[a.Name] = a.Value
					}
					if bindings["author_id"] != int64(42) || bindings["source_post_id"] != int64(1) {
						t.Fatal(bindings)
					}
				}
				if strings.HasPrefix(call.sql, "INSERT INTO n_post_media") {
					media++
					if !strings.Contains(call.sql, "owner_user_id=:user_id") || !strings.Contains(call.sql, "status IN ('uploaded','processing','ready')") {
						t.Fatal(call.sql)
					}
				}
				if strings.HasPrefix(call.sql, "MERGE INTO n_tags") {
					tags++
				}
				if strings.HasPrefix(call.sql, "INSERT INTO n_post_mentions") {
					mentions++
				}
			}
			if tc.want == nil && (media != 2 || tags != 1 || mentions != 1) {
				t.Fatal(media, tags, mentions)
			}
		})
	}
}

func TestCreatePostAtomicValidationAndRelationLimits(t *testing.T) {
	ref := int64(1)
	tooLarge := int64(9007199254740992)
	for _, tc := range []struct {
		name  string
		input PostCreateInput
		want  error
	}{
		{"empty", PostCreateInput{Content: " \u00a0\n"}, errPostContentEmpty},
		{"invalid visibility", PostCreateInput{Content: "x", Visibility: "everyone"}, errPostCreateInvalid},
		{"multiple references", PostCreateInput{Content: "x", ReplyToPostID: &ref, QuotedPostID: &ref}, errPostCreateInvalid},
		{"unsafe reference", PostCreateInput{Content: "x", ReplyToPostID: &tooLarge}, errPostCreateInvalid},
	} {
		t.Run(tc.name, func(t *testing.T) {
			state := &createPostState{}
			db := sql.OpenDB(createPostConnector{state})
			defer db.Close()
			_, err := (OracleSessions{db}).CreatePostAtomic(context.Background(), 42, tc.input)
			if !errors.Is(err, tc.want) || len(state.calls) != 0 {
				t.Fatal(err, state.calls)
			}
		})
	}
	state := &createPostState{}
	db := sql.OpenDB(createPostConnector{state})
	defer db.Close()
	postID, err := (OracleSessions{db}).CreatePostAtomic(context.Background(), 42, PostCreateInput{RepostOfPostID: &ref})
	if err != nil || postID != 100 || state.commits != 1 {
		t.Fatal(postID, err, state.commits)
	}
	var kinds []any
	for _, call := range state.calls {
		if strings.HasPrefix(call.sql, "INSERT INTO n_posts") {
			for _, arg := range call.args {
				if arg.Name == "post_type" {
					kinds = append(kinds, arg.Value)
				}
			}
		}
	}
	if len(kinds) != 1 || kinds[0] != "repost" {
		t.Fatal(kinds)
	}
	if got := uniquePostIDs([]float64{1, 1, 2, 3, 4, 5}, 4); len(got) != 4 || got[0] != 1 || got[3] != 4 {
		t.Fatal(got)
	}
	if got := uniquePostTags([]string{" \u00a0#cat ", "cat", "#CAT", "#", " # dog "}); len(got) != 3 || got[0] != "cat" || got[1] != "CAT" || got[2] != "dog" {
		t.Fatal(got)
	}
}

func TestCreatePostAtomicRollbackFailureIsNotReportedAsMediaError(t *testing.T) {
	state := &createPostState{driverState: driverState{fail: "rollback"}, badMedia: true}
	db := sql.OpenDB(createPostConnector{state})
	defer db.Close()
	id, err := (OracleSessions{db}).CreatePostAtomic(context.Background(), 42, PostCreateInput{Content: "text", MediaIDs: []float64{7}})
	if id != 0 || !errors.Is(err, errSessionStore) || state.rollbacks != 1 || state.commits != 0 {
		t.Fatal(id, err, state.rollbacks, state.commits)
	}
}

func TestCreatePostAtomicPreservesNumericRelationBindings(t *testing.T) {
	state := &createPostState{}
	db := sql.OpenDB(createPostConnector{state})
	defer db.Close()
	_, err := (OracleSessions{db}).CreatePostAtomic(context.Background(), 42, PostCreateInput{Content: "text", MediaIDs: []float64{7.5, 7.5, 0, -1, 8, 9}, Mentions: []float64{9.25, 9.25}})
	if err != nil {
		t.Fatal(err)
	}
	var media, mentions []float64
	for _, call := range state.calls {
		for _, arg := range call.args {
			if strings.HasPrefix(call.sql, "INSERT INTO n_post_media") && arg.Name == "media_id" {
				media = append(media, arg.Value.(float64))
			}
			if strings.HasPrefix(call.sql, "INSERT INTO n_post_mentions") && arg.Name == "user_id" {
				mentions = append(mentions, arg.Value.(float64))
			}
		}
	}
	if len(media) != 4 || media[0] != 7.5 || media[1] != 0 || media[2] != -1 || media[3] != 8 || len(mentions) != 1 || mentions[0] != 9.25 {
		t.Fatal(media, mentions)
	}
}
