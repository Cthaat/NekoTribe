package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
)

type postMarkdownFixture struct {
	*postPollFixture
	body       *string
	postType   string
	readError  error
	writeError bool
	reads      int
}

func newPostMarkdownFixture(t *testing.T, target postPollTarget) *postMarkdownFixture {
	t.Helper()
	db := newPostPollFixture(t, target)
	md := postFeatureSchemaFixture(t, contracts.PostMarkdownSchemaCatalog)
	for name, table := range md.snapshot["tables"].(map[string]any) {
		db.snapshot["tables"].(map[string]any)[name] = table
	}
	return &postMarkdownFixture{postPollFixture: db, postType: "post"}
}

type postMarkdownFixtureConn struct {
	*postPollFixtureConn
	f      *postMarkdownFixture
	body   *string
	locked bool
}

func (f *postMarkdownFixture) Connect(ctx context.Context) (driver.Conn, error) {
	conn, err := f.postPollFixture.Connect(ctx)
	if err != nil {
		return nil, err
	}
	return &postMarkdownFixtureConn{postPollFixtureConn: conn.(*postPollFixtureConn), f: f}, nil
}

func (c *postMarkdownFixtureConn) Begin() (driver.Tx, error) {
	if _, err := c.postPollFixtureConn.Begin(); err != nil {
		return nil, err
	}
	c.body, c.locked = c.f.body, false
	return c, nil
}

func (c *postMarkdownFixtureConn) Commit() error {
	if err := c.postPollFixtureConn.Commit(); err != nil {
		return err
	}
	c.f.body = c.body
	return nil
}

func (c *postMarkdownFixtureConn) QueryContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	bind := func(key string) driver.Value { return directFixtureBind(args, key) }
	values := func(items ...driver.Value) driver.Rows { return &alertRows{values: items} }
	noRows := emptyRows{&c.f.driverState}
	switch {
	case query == postMarkdown.SQL["read"]:
		c.f.reads++
		if c.f.readError != nil {
			return nil, c.f.readError
		}
		if bind("post_id") != c.f.target.post || (bind("is_group") == int64(1)) != (c.f.target.group != 0) {
			return nil, errors.New("incorrect Markdown source")
		}
		body := c.f.body
		if c.txOpen {
			body = c.body
		}
		if body == nil {
			return noRows, nil
		}
		return values(*body), nil
	case query == postMarkdown.SQL["present"]:
		if c.f.snapshot["tables"].(map[string]any)["N_POST_MARKDOWN"] == nil {
			return noRows, nil
		}
		return values(int64(1)), nil
	case strings.HasPrefix(query, "SELECT author_id,is_deleted,post_type,"):
		if !c.txOpen || !strings.Contains(query, "FOR UPDATE") {
			return nil, errors.New("post edit was not locked")
		}
		c.locked = true
		return values(int64(42), int64(0), c.f.postType, "excerpt", "public"), nil
	case strings.HasPrefix(query, "SELECT COUNT(*) FROM n_post_media"):
		return values(int64(0)), nil
	}
	return c.postPollFixtureConn.QueryContext(ctx, query, args)
}

func (c *postMarkdownFixtureConn) ExecContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Result, error) {
	bind := func(key string) driver.Value { return directFixtureBind(args, key) }
	switch {
	case query == postMarkdown.SQL["insert"]:
		if !c.txOpen || !c.wrotePost && !c.locked || c.f.writeError {
			return nil, errors.New("Markdown insert unavailable")
		}
		post, group := bind("post_id"), bind("group_post_id")
		if c.f.target.group == 0 && (post != c.f.target.post || group != nil) ||
			c.f.target.group != 0 && (post != nil || group != c.f.target.post) {
			return nil, errors.New("incorrect Markdown parent bind")
		}
		text := bind("markdown_body").(string)
		c.body = &text
	case query == postMarkdown.SQL["update"]:
		if !c.txOpen || !c.locked || c.f.writeError || bind("post_id") != c.f.target.post {
			return nil, errors.New("Markdown update unavailable")
		}
		if c.body == nil {
			return driver.RowsAffected(0), nil
		}
		text := bind("markdown_body").(string)
		c.body = &text
	case query == postMarkdown.SQL["remove"]:
		if !c.txOpen || !c.locked || c.f.writeError || bind("post_id") != c.f.target.post {
			return nil, errors.New("Markdown clear unavailable")
		}
		if c.body == nil {
			return driver.RowsAffected(0), nil
		}
		c.body = nil
	case strings.HasPrefix(query, "UPDATE n_posts SET"):
		if !c.txOpen || !c.locked {
			return nil, errors.New("ordinary update without lock")
		}
	default:
		return c.postPollFixtureConn.ExecContext(ctx, query, args)
	}
	return driver.RowsAffected(1), nil
}

func TestPostMarkdownCreationCommitsOrRollsBackInBothScopes(t *testing.T) {
	ctx := context.Background()
	long := "  # Title\n\n~~~go\nfmt.Println(42)\n~~~\n" + strings.Repeat("猫", 4000)
	for _, target := range []postPollTarget{{post: 5}, {group: 7, post: 5}} {
		for _, injectFailure := range []bool{false, true} {
			f := newPostMarkdownFixture(t, target)
			f.writeError = injectFailure
			db := sql.OpenDB(f)
			store := OracleSessions{db}
			var err error
			if target.group == 0 {
				_, err = store.CreatePostAtomic(ctx, 42, PostCreateInput{Content: "excerpt", Markdown: &long})
			} else {
				var receipt any
				receipt, err = store.WriteGroupPost(ctx, 42, groupPostMutation{
					action: "create", group: target.group, content: "excerpt", markdown: &long,
				}, StorageURLPolicy{})
				if err == nil && *receipt.(groupPost).Markdown != long {
					t.Fatal("group create response lost raw Markdown")
				}
			}
			if injectFailure {
				if !errors.Is(err, errSessionStore) || f.body != nil || f.commits != 0 || f.rollbacks != 1 {
					t.Fatalf("Markdown failure leaked post: err %v, db %+v", err, f.driverState)
				}
			} else if err != nil || f.body == nil || *f.body != long || f.commits != 1 {
				t.Fatalf("Markdown write failed: err %v, db %+v", err, f.driverState)
			}
			if !injectFailure && target.group != 0 {
				req := groupContentRequest{group: target.group, post: target.post, page: SessionPage{Start: 1, End: 1}, order: "all"}
				result, _, err := store.ReadGroupContent(ctx, 42, req, StorageURLPolicy{})
				if err != nil || result.(groupPost).Markdown == nil || *result.(groupPost).Markdown != long {
					t.Fatalf("group detail Markdown missing, err %v", err)
				}
				before := f.reads
				f.hidden = true
				if _, _, err := store.ReadGroupContent(ctx, 42, req, StorageURLPolicy{}); !errors.Is(err, errGroupDetailMissing) || f.reads != before {
					t.Fatalf("Markdown read before group visibility, err %v", err)
				}
			}
			_ = db.Close()
		}
	}
}

func TestPostMarkdownEditReplacesClearsAndRetains(t *testing.T) {
	ctx := context.Background()
	f := newPostMarkdownFixture(t, postPollTarget{post: 5})
	db := sql.OpenDB(f)
	defer db.Close()
	store := OracleSessions{db}
	change := func(input map[string]any, want error) {
		t.Helper()
		update, validation := readPostUpdateInput(input)
		if validation != "" {
			t.Fatal(validation)
		}
		if err := store.UpdatePostAtomic(ctx, 42, f.target.post, update); !errors.Is(err, want) {
			t.Fatalf("update error %v, want %v", err, want)
		}
	}
	change(map[string]any{"markdown": "# New"}, nil)
	change(map[string]any{"content": "new excerpt"}, nil)
	if f.body == nil || *f.body != "# New" {
		t.Fatal("content edit changed omitted Markdown")
	}
	change(map[string]any{"markdown": "  replaced\n"}, nil)
	body, err := store.ReadAttachedPostMarkdown(ctx, f.target.post)
	if err != nil || body == nil || *body != "  replaced\n" {
		t.Fatalf("Markdown replacement failed: %v, error %v", body, err)
	}
	f.writeError = true
	change(map[string]any{"markdown": nil, "content": "new edit"}, errSessionStore)
	if f.body == nil || *f.body != "  replaced\n" || f.rollbacks != 1 {
		t.Fatal("failed clear changed the previous Markdown")
	}
	f.writeError = false
	change(map[string]any{"markdown": nil}, nil)
	change(map[string]any{"markdown": nil}, nil)
	if f.body != nil {
		t.Fatal("explicit null did not clear Markdown")
	}
	f.postType = "quote"
	change(map[string]any{"markdown": "# Invalid"}, errPostMarkdownInvalid)
	change(map[string]any{"markdown": nil}, errPostMarkdownInvalid)
}

func TestPostMarkdownLegacyReadRequiresConfirmedMissingTable(t *testing.T) {
	ctx := context.Background()
	f := newPostMarkdownFixture(t, postPollTarget{post: 5})
	db := sql.OpenDB(f)
	defer db.Close()
	store := OracleSessions{db}
	f.readError = errors.New("ORA-00942: table does not exist")
	if _, err := store.ReadAttachedPostMarkdown(ctx, f.target.post); !errors.Is(err, errPostMarkdownUnavailable) {
		t.Fatalf("present schema swallowed the read error: %v", err)
	}
	delete(f.snapshot["tables"].(map[string]any), "N_POST_MARKDOWN")
	if body, err := store.ReadAttachedPostMarkdown(ctx, f.target.post); body != nil || err != nil {
		t.Fatalf("old schema blocked plain history: %v, %v", body, err)
	}
	markdown := "# body"
	if _, err := store.CreatePostAtomic(ctx, 42, PostCreateInput{Content: "excerpt", Markdown: &markdown}); !errors.Is(err, errPostMarkdownUnavailable) ||
		f.commits != 0 || f.rollbacks != 0 {
		t.Fatalf("missing schema allowed Markdown transaction: %v", err)
	}
	f.snapshot["owner"].(map[string]any)["schema"] = "OTHER"
	if _, err := store.ReadAttachedPostMarkdown(ctx, f.target.post); !errors.Is(err, errPostMarkdownUnavailable) {
		t.Fatalf("different schema treated as legacy: %v", err)
	}
}

func TestPostMarkdownDraftScheduleAndDuePublication(t *testing.T) {
	ctx := context.Background()
	long := "# Title\n\n" + strings.Repeat("段落\n", 1700) + "\n~~~go\nrun()\n~~~\n"
	for _, group := range []any{nil, int64(7)} {
		f := &postDraftFixture{}
		db := sql.OpenDB(f)
		conn, err := db.Conn(ctx)
		if err != nil {
			t.Fatal(err)
		}
		change := func(update postDraftAction) (postDraftResult, error) {
			return postDraftTx(ctx, conn, func(tx *sql.Tx) (postDraftResult, error) {
				return changePostDraft(ctx, tx, 42, update, StorageURLPolicy{})
			})
		}
		raw, err := json.Marshal(map[string]any{"group_id": group, "content": "excerpt", "markdown": long})
		if err != nil {
			t.Fatal(err)
		}
		payload, err := parsePostDraft(raw)
		if err != nil {
			t.Fatal(err)
		}
		draft, err := change(postDraftAction{kind: "create", body: payload})
		if err != nil || draft.record == nil || len(draft.record.Payload) <= 4000 {
			t.Fatalf("draft save lost long Markdown: %v", err)
		}
		at, _ := parsePostUTCDate("2026-12-01T02:00:00Z")
		request := postDraftAction{kind: "schedule", id: draft.record.ID, when: at}
		if _, err := change(request); !errors.Is(err, errPostMarkdownUnavailable) || f.row.status != "draft" {
			t.Fatalf("schedule accepted unavailable Markdown: %v", err)
		}
		metadata := postFeatureSchemaFixture(t, contracts.PostMarkdownSchemaCatalog)
		f.markdownSchema = &metadata
		if scheduled, err := change(request); err != nil || scheduled.record.Status != "scheduled" {
			t.Fatalf("long draft schedule returned %v", err)
		}
		result, err := postDraftTx(ctx, conn, func(tx *sql.Tx) (postDraftResult, error) {
			return publishDuePostDraft(ctx, tx, draft.record.ID, StorageURLPolicy{})
		})
		if err != nil || result.record.Status != "published" || result.newPostID != 55 || f.posts != 1 || f.markdown == nil || *f.markdown != long {
			t.Fatalf("due publication lost raw Markdown: result %+v, error %v", result, err)
		}
		_ = conn.Close()
		_ = db.Close()
	}
}
