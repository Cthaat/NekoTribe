package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"slices"
	"strings"
	"testing"
)

type draftFixtureRow struct {
	id, owner                        int64
	group, scheduled, posted, reason driver.Value
	payload, status                  string
}

type postDraftFixture struct {
	driverState
	row                draftFixtureRow
	posts              int
	fail, availability string
	steps              []string
	markdownSchema     *schemaFixtureConnector
	markdown           *string
}

type postDraftFixtureConn struct {
	*testConn
	f         *postDraftFixture
	row       draftFixtureRow
	post      bool
	savepoint bool
	markdown  *string
}

func (f *postDraftFixture) Connect(context.Context) (driver.Conn, error) {
	return &postDraftFixtureConn{testConn: &testConn{&f.driverState}, f: f}, nil
}
func (*postDraftFixture) Driver() driver.Driver { return testDriver{} }

func (c *postDraftFixtureConn) Begin() (driver.Tx, error) {
	c.row, c.post, c.savepoint = c.f.row, false, false
	c.markdown = c.f.markdown
	return c, nil
}
func (c *postDraftFixtureConn) Commit() error {
	c.f.commits++
	c.f.row = c.row
	if c.post {
		c.f.posts++
		c.f.markdown = c.markdown
	}
	return nil
}
func (c *postDraftFixtureConn) Rollback() error {
	c.f.rollbacks++
	return nil
}

func (c *postDraftFixtureConn) QueryContext(ctx context.Context, stmt string, args []driver.NamedValue) (driver.Rows, error) {
	bind := func(name string) driver.Value { return directFixtureBind(args, name) }
	one := func(values ...driver.Value) (driver.Rows, error) { return &alertRows{values: values}, nil }
	none := func() (driver.Rows, error) { return emptyRows{&c.f.driverState}, nil }
	r := c.row
	switch stmt {
	case postDrafts.SQL["read"], postDrafts.SQL["lock_owner"], postDrafts.SQL["lock_due"]:
		if bind("draft_id") != r.id || r.id == 0 {
			return none()
		}
		if stmt == postDrafts.SQL["lock_due"] {
			if r.status != "scheduled" || c.f.availability == "locked" {
				return none()
			}
			c.f.steps = append(c.f.steps, "claim")
		} else if bind("owner_id") != r.owner {
			return none()
		}
		return one(r.id, r.owner, r.group, r.payload, r.status, r.scheduled, r.posted, r.reason, "2026-12-01T02:01:00.000Z")
	case "SELECT seq_post_draft_id.NEXTVAL FROM dual":
		return one(int64(12))
	case "SELECT seq_post_id.NEXTVAL FROM dual", "SELECT seq_group_post_id.NEXTVAL AS id FROM dual":
		return one(int64(55))
	case publishPolicy.SQL["lock"]:
		return one(r.owner)
	case lockGroupContentSQL:
		return one(r.group)
	case publishPolicy.SQL["allowed"], canViewGroupContentSQL, canModerateGroupContentSQL:
		return one(int64(1))
	case canPostGroupContentSQL:
		if c.f.fail == "rights revoked" {
			return one(int64(0))
		}
		return one(int64(1))
	case lockPostMediaSQL:
		return none()
	case schemaOwnerSQL:
		return &schemaFixtureRows{columns: []string{"USER_NAME", "SCHEMA_NAME"}, values: [][]driver.Value{{"NEKO", "NEKO"}}}, nil
	default:
		if c.f.markdownSchema != nil {
			return (&schemaFixtureConn{*c.f.markdownSchema}).QueryContext(ctx, stmt, args)
		}
		if strings.Contains(stmt, "FROM user_tables") {
			return none()
		}
		return nil, errors.New("unexpected draft query")
	}
}

func (c *postDraftFixtureConn) ExecContext(_ context.Context, stmt string, args []driver.NamedValue) (driver.Result, error) {
	bind := func(name string) driver.Value { return directFixtureBind(args, name) }
	ownerMatch := bind("draft_id") == c.row.id && c.row.id != 0 && bind("owner_id") == c.row.owner
	switch stmt {
	case postDrafts.SQL["insert"]:
		c.row = draftFixtureRow{id: bind("draft_id").(int64), owner: bind("owner_id").(int64),
			group: bind("group_id"), payload: bind("payload_json").(string), status: "draft"}
	case postDrafts.SQL["edit"]:
		if !ownerMatch || c.row.status == "published" {
			return driver.RowsAffected(0), nil
		}
		c.row.group, c.row.payload, c.row.status, c.row.scheduled, c.row.reason =
			bind("group_id"), bind("payload_json").(string), "draft", nil, nil
	case postDrafts.SQL["schedule"], postDrafts.SQL["unschedule"]:
		if !ownerMatch || c.row.status == "published" || c.f.fail == "past schedule" {
			return driver.RowsAffected(0), nil
		}
		c.row.status, c.row.scheduled, c.row.reason = "draft", nil, nil
		if stmt == postDrafts.SQL["schedule"] {
			c.row.status, c.row.scheduled = "scheduled", bind("scheduled_at")
		}
	case postDrafts.SQL["remove"]:
		if !ownerMatch {
			return driver.RowsAffected(0), nil
		}
		c.row = draftFixtureRow{}
	case insertPostAtomicSQL, insertGroupPostSQL:
		if c.f.fail == "db unavailable" {
			return nil, errors.New("private database detail")
		}
		c.f.steps = append(c.f.steps, "insert post")
		c.post = true
	case postMarkdown.SQL["insert"]:
		postID, groupPostID := bind("post_id"), bind("group_post_id")
		if !c.post || c.row.group == nil && (postID != int64(55) || groupPostID != nil) ||
			c.row.group != nil && (postID != nil || groupPostID != int64(55)) {
			return nil, errors.New("Markdown not written with correct draft post")
		}
		body := bind("markdown_body").(string)
		c.markdown = &body
	case postDrafts.SQL["published"]:
		if !ownerMatch || !c.post {
			return nil, errors.New("publication was not part of the draft transaction")
		}
		c.row.posted, c.row.status, c.row.reason = bind("post_id"), "published", nil
	case postDraftSavepoint:
		c.f.steps = append(c.f.steps, "savepoint")
		c.savepoint = true
	case postDraftRollback:
		if !c.savepoint {
			return nil, errors.New("missing publication savepoint")
		}
		c.f.steps = append(c.f.steps, "rollback to savepoint")
		c.post = false
		c.markdown = c.f.markdown
	case postDrafts.SQL["failed"]:
		if !ownerMatch || c.row.status != "scheduled" || c.post {
			return nil, errors.New("draft failed with the post still pending")
		}
		c.f.steps = append(c.f.steps, "record failure")
		c.row.status, c.row.reason = "failed", bind("reason")
	default:
		return nil, errors.New("unexpected draft mutation")
	}
	return driver.RowsAffected(1), nil
}

func TestPostDraftOwnerEditsScheduleAndPublication(t *testing.T) {
	ctx := context.Background()
	f := &postDraftFixture{}
	db := sql.OpenDB(f)
	defer db.Close()
	conn, err := db.Conn(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	change := func(owner int64, action postDraftAction, want error) postDraftResult {
		t.Helper()
		result, err := postDraftTx(ctx, conn, func(tx *sql.Tx) (postDraftResult, error) {
			return changePostDraft(ctx, tx, owner, action, StorageURLPolicy{})
		})
		if !errors.Is(err, want) {
			t.Fatalf("%s returned %v, want %v", action.kind, err, want)
		}
		return result
	}
	parse := func(raw string) postDraftPayload {
		t.Helper()
		body, err := parsePostDraft([]byte(raw))
		if err != nil {
			t.Fatal(err)
		}
		return body
	}
	created := change(42, postDraftAction{kind: "create", body: parse(`{"group_id":null,"content":""}`)}, nil)
	id := created.record.ID
	at, _ := parsePostUTCDate("2026-12-01T02:00:00.000Z")
	change(42, postDraftAction{kind: "schedule", id: id, when: at}, errPostContentEmpty)
	change(11, postDraftAction{kind: "remove", id: id}, errPostDraftMissing)
	change(11, postDraftAction{kind: "publish", id: id}, errPostDraftMissing)
	pollDraft := parse(`{"group_id":null,"content":"vote","poll":{"options":["a","b"],"multiple":false,"closes_at":"2026-12-01T02:00:00Z"}}`)
	change(42, postDraftAction{kind: "edit", id: id, body: pollDraft}, nil)
	change(42, postDraftAction{kind: "schedule", id: id, when: at}, errPostDraftPollCutoff)
	mediaDraft := parse(`{"group_id":null,"content":"with attachment","media_ids":[8]}`)
	change(42, postDraftAction{kind: "edit", id: id, body: mediaDraft}, nil)
	change(42, postDraftAction{kind: "schedule", id: id, when: at}, nil)
	change(42, postDraftAction{kind: "publish", id: id}, errPostMediaUnavailable)
	if f.row.status != "scheduled" || f.row.reason != nil || f.posts != 0 {
		t.Fatalf("failed manual publication changed schedule: %+v", f.row)
	}
	fullCLOB := `{"group_id":null,"content":"` + strings.Repeat("a", 4000) + `","location":"building"}`
	changed := change(42, postDraftAction{kind: "edit", id: id, body: parse(fullCLOB)}, nil)
	if len(changed.record.Payload) <= 4000 {
		t.Fatal("draft CLOB payload was truncated")
	}
	f.fail = "past schedule"
	change(42, postDraftAction{kind: "schedule", id: id, when: at}, errPostDraftSchedule)
	f.fail = ""
	queued := change(42, postDraftAction{kind: "schedule", id: id, when: at}, nil)
	if queued.record.Status != "scheduled" || queued.record.ScheduledAt == nil {
		t.Fatalf("draft not scheduled: %+v", queued.record)
	}
	unscheduled := change(42, postDraftAction{kind: "unschedule", id: id}, nil)
	if unscheduled.record.Status != "draft" || unscheduled.record.ScheduledAt != nil {
		t.Fatalf("draft not unscheduled: %+v", unscheduled.record)
	}
	change(42, postDraftAction{kind: "schedule", id: id, when: at}, nil)
	change(42, postDraftAction{kind: "edit", id: id, body: parse(fullCLOB)}, nil)
	if f.row.status != "draft" || f.row.scheduled != nil {
		t.Fatalf("edit retained a schedule: %+v", f.row)
	}
	first := change(42, postDraftAction{kind: "publish", id: id}, nil)
	repeat := change(42, postDraftAction{kind: "publish", id: id}, nil)
	if first.record.Status != "published" || first.newPostID != 55 || repeat.newPostID != 0 ||
		repeat.record.PublishedID == nil || *repeat.record.PublishedID != 55 || f.posts != 1 {
		t.Fatalf("duplicate publication: first %+v, repeat %+v, posts %d", first, repeat, f.posts)
	}
	change(42, postDraftAction{kind: "schedule", id: id, when: at}, errPostDraftPublished)
	change(42, postDraftAction{kind: "remove", id: id}, nil)
	if f.row.id != 0 || f.posts != 1 {
		t.Fatal("removing the receipt changed its published post")
	}
}

func TestPostDraftDueWorkerClassifiesFailuresAndKeepsCommittedReceipt(t *testing.T) {
	for _, tc := range []struct {
		name, payload, problem, availability, status, reason string
		group                                                driver.Value
		steps                                                []string
		posts                                                int
		want                                                 error
	}{
		{"success", `{"group_id":null,"content":"hello"}`, "", "", "published", "", nil, []string{"claim", "savepoint", "insert post"}, 1, nil},
		{"content unavailable", `{"group_id":null,"content":"hello","media_ids":[8]}`, "", "", "failed", "content_unavailable", nil,
			[]string{"claim", "savepoint", "insert post", "rollback to savepoint", "record failure"}, 0, nil},
		{"rights revoked", `{"group_id":7,"content":"hello"}`, "rights revoked", "", "failed", "permission_denied", int64(7),
			[]string{"claim", "savepoint", "rollback to savepoint", "record failure"}, 0, nil},
		{"group published", `{"group_id":7,"content":"hello"}`, "", "", "published", "", int64(7),
			[]string{"claim", "savepoint", "insert post"}, 1, nil},
		{"temporary", `{"group_id":null,"content":"hello"}`, "db unavailable", "", "scheduled", "", nil, []string{"claim", "savepoint"}, 0, errSessionStore},
		{"already locked", `{"group_id":null,"content":"hello"}`, "", "locked", "scheduled", "", nil, nil, 0, nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx := context.Background()
			f := &postDraftFixture{
				row:  draftFixtureRow{id: 12, owner: 42, group: tc.group, payload: tc.payload, status: "scheduled"},
				fail: tc.problem, availability: tc.availability,
			}
			db := sql.OpenDB(f)
			defer db.Close()
			conn, err := db.Conn(ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close()
			run := func() (postDraftResult, error) {
				return postDraftTx(ctx, conn, func(tx *sql.Tx) (postDraftResult, error) {
					return publishDuePostDraft(ctx, tx, 12, StorageURLPolicy{})
				})
			}
			result, err := run()
			reason, _ := f.row.reason.(string)
			if !errors.Is(err, tc.want) || f.row.status != tc.status || reason != tc.reason || f.posts != tc.posts || !slices.Equal(f.steps, tc.steps) {
				t.Fatalf("result %+v, err %v, status %s, reason %s, posts %d, steps %v", result, err, f.row.status, reason, f.posts, f.steps)
			}
			if tc.status == "published" {
				if repeat, err := run(); err != nil || repeat.newPostID != 0 || f.posts != 1 {
					t.Fatalf("another claim published a post: result %+v, err %v", repeat, err)
				}
			}
		})
	}
}

func TestPostDraftSchemaUnavailableStopsReadsAndWorker(t *testing.T) {
	f := &postDraftFixture{}
	db := sql.OpenDB(f)
	defer db.Close()
	repo := OracleSessions{db}
	if _, err := repo.ListPostDrafts(context.Background(), 42, postDraftQuery{limit: 20}); !errors.Is(err, errPostDraftUnavailable) {
		t.Fatalf("list error: %v", err)
	}
	if _, err := repo.publishPostDraftBatch(context.Background(), StorageURLPolicy{}); !errors.Is(err, errPostDraftUnavailable) {
		t.Fatalf("sweep error: %v", err)
	}
	if _, err := repo.ChangePostDraft(context.Background(), 42, postDraftAction{kind: "publish", id: 12}, RefreshConfig{}); !errors.Is(err, errPostDraftUnavailable) {
		t.Fatalf("publication readiness error: %v", err)
	}
	if f.commits != 0 || f.rollbacks != 0 {
		t.Fatalf("unready schema reached a write transaction: %+v", f.driverState)
	}
}
