package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"io"
	"reflect"
	"strings"
	"testing"
)

type updatePostSnapshot struct {
	Content  string
	Media    []float64
	Tags     []string
	Mentions []float64
	Updated  bool
}

func updatePostInitial() updatePostSnapshot {
	return updatePostSnapshot{Content: "old", Media: []float64{8}, Tags: []string{"old"}, Mentions: []float64{7}}
}
func cloneUpdate(s updatePostSnapshot) updatePostSnapshot {
	s.Media = append([]float64{}, s.Media...)
	s.Tags = append([]string{}, s.Tags...)
	s.Mentions = append([]float64{}, s.Mentions...)
	return s
}

type updatePostState struct {
	driverState
	saved, pending updatePostSnapshot
	mode           string
	owner          int64
	active         bool
	calls          []listQueryCall
	visibility     string
	mediaKey       string
	retainsPrivate bool
	privateDenied  bool
}
type updatePostConnector struct{ s *updatePostState }
type updatePostConn struct {
	*testConn
	s *updatePostState
}
type updatePostTx struct{ s *updatePostState }
type updatePostRows struct {
	values []driver.Value
	done   bool
}

func (r *updatePostRows) Columns() []string {
	out := make([]string, len(r.values))
	for i := range out {
		out[i] = "VALUE"
	}
	return out
}
func (r *updatePostRows) Close() error { return nil }
func (r *updatePostRows) Next(out []driver.Value) error {
	if r.done {
		return io.EOF
	}
	copy(out, r.values)
	r.done = true
	return nil
}
func (c updatePostConnector) Connect(context.Context) (driver.Conn, error) {
	return &updatePostConn{&testConn{&c.s.driverState}, c.s}, nil
}
func (c updatePostConnector) Driver() driver.Driver { return testDriver{} }
func (c *updatePostConn) Begin() (driver.Tx, error) {
	c.s.active = true
	c.s.pending = cloneUpdate(c.s.saved)
	return &updatePostTx{c.s}, nil
}
func (tx *updatePostTx) Commit() error {
	tx.s.commits++
	tx.s.active = false
	if tx.s.mode == "commit" {
		return errors.New("private commit")
	}
	tx.s.saved = cloneUpdate(tx.s.pending)
	if tx.s.mode == "commit-applied" {
		return errors.New("private uncertain commit")
	}
	return nil
}
func (tx *updatePostTx) Rollback() error {
	tx.s.rollbacks++
	tx.s.active = false
	tx.s.pending = cloneUpdate(tx.s.saved)
	if tx.s.mode == "rollback" {
		return errors.New("private rollback")
	}
	return nil
}
func (c *updatePostConn) QueryContext(_ context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	c.s.calls = append(c.s.calls, listQueryCall{q, args})
	if !c.s.active {
		return nil, errors.New("query outside transaction")
	}
	if c.s.mode == "read" {
		return nil, errors.New("private query")
	}
	if q == publishPolicy.SQL["lock"] {
		return &updatePostRows{values: []driver.Value{int64(42)}}, nil
	}
	if q == publishPolicy.SQL["allowed"] {
		allowed := int64(1)
		if c.s.mode == "muted" {
			allowed = 0
		}
		return &updatePostRows{values: []driver.Value{allowed}}, nil
	}
	if q == lockPostMediaSQL {
		return &updatePostRows{values: []driver.Value{int64(1), c.s.mediaKey}}, nil
	}
	if q == privateMediaBinding.Post {
		if c.s.privateDenied {
			return emptyRows{&c.s.driverState}, nil
		}
		return &updatePostRows{values: []driver.Value{int64(1)}}, nil
	}
	if q == privateMediaBinding.Retained {
		if c.s.retainsPrivate {
			return &updatePostRows{values: []driver.Value{int64(1)}}, nil
		}
		return emptyRows{&c.s.driverState}, nil
	}
	if strings.Contains(q, "FOR UPDATE") {
		if c.s.mode == "missing" {
			return emptyRows{&c.s.driverState}, nil
		}
		kind := "post"
		if c.s.mode == "repost" {
			kind = "repost"
		}
		deleted := int64(0)
		if c.s.mode == "deleted" {
			deleted = 1
		}
		return &updatePostRows{values: []driver.Value{c.s.owner, deleted, kind, c.s.saved.Content, c.s.visibility}}, nil
	}
	if strings.Contains(q, "COUNT(*)") {
		return &updatePostRows{values: []driver.Value{int64(len(c.s.pending.Media))}}, nil
	}
	return nil, errors.New("unexpected query")
}
func (c *updatePostConn) ExecContext(_ context.Context, q string, args []driver.NamedValue) (driver.Result, error) {
	if !c.s.active {
		return nil, errors.New("write outside transaction")
	}
	c.s.calls = append(c.s.calls, listQueryCall{q, args})
	if c.s.mode != "" && strings.HasPrefix(q, c.s.mode) {
		return nil, errors.New("private write")
	}
	binds := map[string]interface{}{}
	for _, arg := range args {
		binds[arg.Name] = arg.Value
	}
	switch {
	case strings.HasPrefix(q, "UPDATE n_posts"):
		if !strings.Contains(q, "author_id=:user_id") || !strings.Contains(q, "is_deleted=0") || binds["user_id"] != int64(42) || binds["post_id"] != int64(20) {
			return nil, errors.New("unguarded write")
		}
		if c.s.mode == "race" {
			return driver.RowsAffected(0), nil
		}
		c.s.pending.Updated = true
		if v, ok := binds["content"]; ok {
			if v == nil {
				c.s.pending.Content = ""
			} else {
				c.s.pending.Content = v.(string)
			}
		}
	case strings.HasPrefix(q, "DELETE FROM n_post_media"):
		c.s.pending.Media = []float64{}
	case strings.HasPrefix(q, "INSERT INTO n_post_media"):
		id := binds["media_id"].(float64)
		if id == 999 {
			return driver.RowsAffected(0), nil
		}
		c.s.pending.Media = append(c.s.pending.Media, id)
	case strings.HasPrefix(q, "DELETE FROM n_post_tags"):
		c.s.pending.Tags = []string{}
	case strings.HasPrefix(q, "MERGE INTO n_tags"):
	case strings.HasPrefix(q, "INSERT INTO n_post_tags"):
		c.s.pending.Tags = append(c.s.pending.Tags, binds["name"].(string))
	case strings.HasPrefix(q, "DELETE FROM n_post_mentions"):
		c.s.pending.Mentions = []float64{}
	case strings.HasPrefix(q, "INSERT INTO n_post_mentions"):
		c.s.pending.Mentions = append(c.s.pending.Mentions, binds["user_id"].(float64))
	default:
		return nil, errors.New("unexpected write")
	}
	return driver.RowsAffected(1), nil
}
func updatePostInput() PostUpdateInput {
	content := "new"
	media := []float64{3, 3, 4}
	tags := []string{"#new"}
	mentions := []float64{9}
	return PostUpdateInput{Content: &content, MediaIDs: &media, Tags: &tags, Mentions: &mentions}
}
func TestPostUpdateAtomic(t *testing.T) {
	for _, mode := range []string{"success", "muted", "missing", "deleted", "other", "race", "read", "UPDATE n_posts", "DELETE FROM n_post_media", "INSERT INTO n_post_media", "DELETE FROM n_post_tags", "MERGE INTO n_tags", "INSERT INTO n_post_tags", "DELETE FROM n_post_mentions", "INSERT INTO n_post_mentions", "commit", "commit-applied", "bad-media", "empty", "noop", "clear"} {
		t.Run(mode, func(t *testing.T) {
			state := &updatePostState{saved: updatePostInitial(), mode: mode, owner: 42}
			if mode == "other" {
				state.owner = 7
			}
			db := sql.OpenDB(updatePostConnector{state})
			defer db.Close()
			input := updatePostInput()
			if mode == "bad-media" {
				ids := []float64{3, 999}
				input.MediaIDs = &ids
			}
			if mode == "noop" {
				input = PostUpdateInput{}
			}
			if mode == "empty" {
				empty := ""
				ids := []float64{}
				input.Content = &empty
				input.MediaIDs = &ids
			}
			if mode == "clear" {
				input.Content = nil
				ids := []float64{}
				tags := []string{}
				input.MediaIDs = &ids
				input.Tags = &tags
				input.Mentions = &ids
			}
			err := (OracleSessions{db}).UpdatePostAtomic(context.Background(), 42, 20, input)
			if mode == "muted" && (!errors.Is(err, errPublishForbidden) || len(state.calls) != 2) {
				t.Fatal("expected moderation denial before post access", err, state.calls)
			}
			success := mode == "success" || mode == "noop" || mode == "clear"
			if success != (err == nil) {
				t.Fatalf("mode=%s err=%v", mode, err)
			}
			if err != nil && strings.Contains(err.Error(), "private") {
				t.Fatal(err)
			}
			if success || mode == "commit-applied" {
				if state.commits != 1 {
					t.Fatal(state.commits)
				}
			} else {
				if !reflect.DeepEqual(state.saved, updatePostInitial()) {
					t.Fatal("partial write", state.saved)
				}
				if mode != "commit" && state.rollbacks != 1 {
					t.Fatal("missing rollback", state.rollbacks)
				}
			}
			if mode == "success" {
				want := updatePostSnapshot{Content: "new", Media: []float64{3, 4}, Tags: []string{"new"}, Mentions: []float64{9}, Updated: true}
				if !reflect.DeepEqual(state.saved, want) {
					t.Fatal(state.saved)
				}
			}
			if mode == "noop" && !reflect.DeepEqual(state.saved, updatePostInitial()) {
				t.Fatal(state.saved)
			}
			if mode == "clear" && (len(state.saved.Media) != 0 || len(state.saved.Tags) != 0 || len(state.saved.Mentions) != 0) {
				t.Fatal(state.saved)
			}
		})
	}
}
