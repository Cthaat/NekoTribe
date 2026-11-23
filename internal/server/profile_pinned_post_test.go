package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
)

func TestProfilePinnedPostRoutesRequireAccess(t *testing.T) {
	handler := NewHandler(nil, nil, CorsPolicy{})
	for _, route := range []struct{ method, path string }{
		{http.MethodGet, "/api/v2/users/7/pinned-post"},
		{http.MethodPut, "/api/v2/users/me/pinned-post"},
		{http.MethodDelete, "/api/v2/users/me/pinned-post"},
	} {
		res := httptest.NewRecorder()
		handler.ServeHTTP(res, httptest.NewRequest(route.method, route.path, nil))
		if res.Code != http.StatusUnauthorized || res.Header().Get("Cache-Control") != "private, no-store" {
			t.Errorf("%s %s returned %d: %s", route.method, route.path, res.Code, res.Body)
		}
	}
}

type profilePinHTTPFixture struct {
	*postFixture
	id, owner, viewer, profile int64
}

func (f *profilePinHTTPFixture) ProfilePinnedPostID(_ context.Context, viewer, profile int64) (int64, error) {
	f.viewer, f.profile = viewer, profile
	return f.id, nil
}

func (f *profilePinHTTPFixture) SetProfilePinnedPost(_ context.Context, owner int64, id *int64) error {
	f.owner = owner
	if id == nil {
		f.id = 0
	} else {
		f.id = *id
	}
	return nil
}

func (f *profilePinHTTPFixture) ReadAttachedPostMarkdown(_ context.Context, _ int64) (*string, error) {
	return f.post.Markdown, nil
}

func TestProfilePinnedPostHTTPHydratesWithViewerAndNoViewIncrement(t *testing.T) {
	codec, tokens := fixture(t)
	markdown := "  ## Pinned\n"
	f := &profilePinHTTPFixture{postFixture: &postFixture{
		memorySessions: store(),
		post:           PostDetail{PostID: 1, Author: PublicUser{UserID: 7}, Content: "pin", Stats: PostStats{ViewsCount: 19}, Markdown: &markdown},
	}}
	h := NewHandler(codec, f, CorsPolicy{})
	const self = "/api/v2/users/me/pinned-post"
	const profile = "/api/v2/users/7/pinned-post"
	request := func(method, path, body string, status int) string {
		t.Helper()
		req := httptest.NewRequest(method, path, strings.NewReader(body))
		req.AddCookie(&http.Cookie{Name: "access_token", Value: tokens["access-hs256"]})
		res := httptest.NewRecorder()
		h.ServeHTTP(res, req)
		if res.Code != status || res.Header().Get("Cache-Control") != "private, no-store" {
			t.Fatalf("%s %s returned %d: %s", method, path, res.Code, res.Body)
		}
		return res.Body.String()
	}
	if body := request(http.MethodGet, profile, "", 200); !strings.Contains(body, `"post":null`) || len(f.events) != 0 {
		t.Fatalf("unexpected empty pin response %s, events %v", body, f.events)
	}
	for _, invalid := range []string{`{"post_id":"1"}`, `{"post_id":1,"viewer_id":7}`, `{"post_id":0}`, `{"post_id":9007199254740992}`} {
		request(http.MethodPut, self, invalid, 400)
	}
	if body := request(http.MethodPut, self, `{"post_id":1}`, 200); !strings.Contains(body, `"data":{"post_id":1}`) || f.owner != 42 {
		t.Fatalf("unexpected set response %s, owner %d", body, f.owner)
	}
	var response struct {
		Data struct{ Post *PostDetail }
	}
	body := request(http.MethodGet, profile+"?viewer_id=99", "", 200)
	if err := json.Unmarshal([]byte(body), &response); err != nil || response.Data.Post == nil ||
		response.Data.Post.Content != "pin" || response.Data.Post.Stats.ViewsCount != 19 ||
		response.Data.Post.Markdown == nil || *response.Data.Post.Markdown != markdown ||
		f.viewer != 42 || f.profile != 7 || !slices.Equal(f.events, []string{"post", "author", "media-ready", "media", "tags", "mentions"}) {
		t.Fatalf("unexpected hydrated pin %s, events %v", body, f.events)
	}
	f.missing = true
	f.events = nil
	if body := request(http.MethodGet, profile, "", 200); !strings.Contains(body, `"post":null`) || !slices.Equal(f.events, []string{"post"}) {
		t.Fatalf("removed pin returned %s, events %v", body, f.events)
	}
	for range 2 {
		if body := request(http.MethodDelete, self, "", 200); !strings.Contains(body, `"data":null`) {
			t.Fatalf("clear returned %s", body)
		}
	}
}

type profilePinFixture struct {
	schemaFixtureConnector
	driverState
	id    int64
	steps []string
}

type profilePinFixtureConn struct {
	*testConn
	f      *profilePinFixture
	id     int64
	inTx   bool
	locked bool
}

func (f *profilePinFixture) Connect(context.Context) (driver.Conn, error) {
	return &profilePinFixtureConn{testConn: &testConn{&f.driverState}, f: f}, nil
}
func (c *profilePinFixtureConn) Begin() (driver.Tx, error) {
	c.id, c.inTx, c.locked = c.f.id, true, false
	return c, nil
}
func (c *profilePinFixtureConn) Commit() error {
	c.f.commits++
	c.f.id, c.inTx = c.id, false
	return nil
}
func (c *profilePinFixtureConn) Rollback() error {
	c.f.rollbacks++
	c.inTx = false
	return nil
}

func (c *profilePinFixtureConn) QueryContext(ctx context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	bind := func(key string) driver.Value { return directFixtureBind(args, key) }
	one := func(id int64) (driver.Rows, error) { return &alertRows{values: []driver.Value{id}}, nil }
	none := func() (driver.Rows, error) { return emptyRows{&c.f.driverState}, nil }
	switch q {
	case profilePinnedPostSQL["owner"]:
		if !c.inTx || bind("user_id") != int64(42) {
			return nil, errors.New("unexpected owner lock")
		}
		c.locked = true
		c.f.steps = append(c.f.steps, "owner")
		return one(42)
	case profilePinnedPostSQL["eligible"]:
		if !c.locked || bind("user_id") != int64(42) {
			return nil, errors.New("unscoped eligibility lookup")
		}
		c.f.steps = append(c.f.steps, "eligible")
		id, _ := bind("post_id").(int64)
		if id == 12 || id == 13 {
			return one(id)
		}
		return none()
	case profilePinnedPostSQL["read"]:
		if c.f.id == 0 || bind("profile_id") != int64(42) || bind("viewer_id") == int64(9) {
			return none()
		}
		return one(c.f.id)
	default:
		return (&schemaFixtureConn{c.f.schemaFixtureConnector}).QueryContext(ctx, q, args)
	}
}

func (c *profilePinFixtureConn) ExecContext(_ context.Context, q string, args []driver.NamedValue) (driver.Result, error) {
	if !c.inTx || !c.locked || directFixtureBind(args, "user_id") != int64(42) {
		return nil, errors.New("pin mutation without owner lock")
	}
	switch q {
	case profilePinnedPostSQL["write"]:
		c.f.steps = append(c.f.steps, "write")
		c.id = directFixtureBind(args, "post_id").(int64)
	case profilePinnedPostSQL["remove"]:
		c.f.steps = append(c.f.steps, "remove")
		if c.id == 0 {
			return driver.RowsAffected(0), nil
		}
		c.id = 0
	default:
		return nil, errors.New("unexpected pin mutation")
	}
	return driver.RowsAffected(1), nil
}

func TestProfilePinnedPostOwnerLockReplacementAndReadiness(t *testing.T) {
	var snapshot map[string]any
	if err := json.Unmarshal([]byte(`{
		"owner":{"user":"NEKO","schema":"NEKO"},
		"ledgerPresent":false,
		"tables":{"N_USER_PINNED_POSTS":{
			"columns":[
				{"COLUMN_NAME":"USER_ID","DATA_TYPE":"NUMBER","DATA_PRECISION":10,"DATA_SCALE":0,"NULLABLE":"N"},
				{"COLUMN_NAME":"POST_ID","DATA_TYPE":"NUMBER","DATA_PRECISION":15,"DATA_SCALE":0,"NULLABLE":"N"}],
			"constraints":[
				{"CONSTRAINT_NAME":"PIN_PK","CONSTRAINT_TYPE":"P","STATUS":"ENABLED","VALIDATED":"VALIDATED","columns":["USER_ID"]},
				{"CONSTRAINT_NAME":"PIN_FK_OWNER","CONSTRAINT_TYPE":"R","STATUS":"ENABLED","VALIDATED":"VALIDATED","DELETE_RULE":"CASCADE",
					"REFERENCED_TABLE":"N_USERS","REFERENCED_OWNER":"NEKO","columns":["USER_ID"],"referencedColumns":["USER_ID"]},
				{"CONSTRAINT_NAME":"PIN_FK_POST","CONSTRAINT_TYPE":"R","STATUS":"ENABLED","VALIDATED":"VALIDATED","DELETE_RULE":"CASCADE",
					"REFERENCED_TABLE":"N_POSTS","REFERENCED_OWNER":"NEKO","columns":["POST_ID"],"referencedColumns":["POST_ID"]}]
		}}}`), &snapshot); err != nil {
		t.Fatal(err)
	}
	f := &profilePinFixture{schemaFixtureConnector: schemaFixtureConnector{snapshot, new([]string), new(int)}}
	db := sql.OpenDB(f)
	defer db.Close()
	repo := OracleSessions{db}
	ctx := context.Background()
	for _, id := range []int64{12, 13} {
		f.steps = nil
		if err := repo.SetProfilePinnedPost(ctx, 42, &id); err != nil || !slices.Equal(f.steps, []string{"owner", "eligible", "write"}) || f.id != id {
			t.Fatalf("set %d: pin %d, steps %v, err %v", id, f.id, f.steps, err)
		}
	}
	foreign := int64(14)
	if err := repo.SetProfilePinnedPost(ctx, 42, &foreign); !errors.Is(err, errProfilePinPostMissing) || f.id != 13 || f.rollbacks != 1 {
		t.Fatalf("foreign post changed pin, id %d, err %v", f.id, err)
	}
	if id, err := repo.ProfilePinnedPostID(ctx, 42, 42); err != nil || id != 13 {
		t.Fatalf("visible pin id %d, err %v", id, err)
	}
	if id, err := repo.ProfilePinnedPostID(ctx, 9, 42); err != nil || id != 0 {
		t.Fatalf("unreadable pin id %d, err %v", id, err)
	}
	for range 2 {
		f.steps = nil
		if err := repo.SetProfilePinnedPost(ctx, 42, nil); err != nil || !slices.Equal(f.steps, []string{"owner", "remove"}) || f.id != 0 {
			t.Fatalf("clear: pin %d, steps %v, err %v", f.id, f.steps, err)
		}
	}
	clear(snapshot["tables"].(map[string]any))
	commits := f.commits
	if _, err := repo.ProfilePinnedPostID(ctx, 42, 42); !errors.Is(err, errProfilePinUnavailable) {
		t.Fatalf("unready read error %v", err)
	}
	if err := repo.SetProfilePinnedPost(ctx, 42, nil); !errors.Is(err, errProfilePinUnavailable) || f.commits != commits {
		t.Fatalf("unready removal committed: err %v, commits %d", err, f.commits)
	}
	for _, stmt := range *f.calls {
		if !strings.HasPrefix(stmt, "SELECT ") {
			t.Fatalf("readiness operation performed mutation: %s", stmt)
		}
	}
}
