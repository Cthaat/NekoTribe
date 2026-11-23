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
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type postPollFixture struct {
	schemaFixtureConnector
	driverState
	target            postPollTarget
	options           []string
	choices           []int64
	multiple, hidden  bool
	denyGroupWrite    bool
	closed, hasBallot bool
	legacy            bool
	fail              string
}

func newPostPollFixture(t *testing.T, target postPollTarget) *postPollFixture {
	t.Helper()
	return &postPollFixture{schemaFixtureConnector: postFeatureSchemaFixture(t, contracts.PostPollsSchemaCatalog), target: target}
}

func postFeatureSchemaFixture(t *testing.T, data []byte) schemaFixtureConnector {
	t.Helper()
	var catalog schemaCatalog
	if err := json.Unmarshal(data, &catalog); err != nil {
		t.Fatal(err)
	}
	tables, sequences, indexes := map[string]any{}, map[string]any{}, map[string]any{}
	for _, step := range catalog.Feature.Steps {
		if step.Kind == "sequence" {
			sequences[step.Name] = map[string]any{"SEQUENCE_NAME": step.Name, "INCREMENT_BY": float64(1), "CYCLE_FLAG": "N"}
			continue
		}
		if step.Kind == "index" {
			var names []string
			if err := json.Unmarshal(step.Columns, &names); err != nil || step.Table == "" || len(names) == 0 {
				t.Fatalf("invalid index metadata for %s: %v", step.Name, err)
			}
			columns := make([]any, 0, len(names))
			for _, name := range names {
				columns = append(columns, map[string]any{"COLUMN_NAME": name, "DESCEND": "ASC"})
			}
			indexes[step.Name] = map[string]any{"INDEX_NAME": step.Name, "TABLE_NAME": step.Table,
				"UNIQUENESS": "NONUNIQUE", "STATUS": "VALID", "columns": columns}
			continue
		}
		var columns []schemaColumn
		if err := json.Unmarshal(step.Columns, &columns); err != nil {
			t.Fatal(err)
		}
		columnRows := make([]any, 0, len(columns))
		for _, col := range columns {
			nullable := "N"
			if col.Nullable {
				nullable = "Y"
			}
			row := map[string]any{"COLUMN_NAME": col.Name, "DATA_TYPE": col.Type, "NULLABLE": nullable, "CHAR_USED": col.CharUsed}
			if col.Default != nil {
				row["DATA_DEFAULT"] = *col.Default
			}
			typ, tail, hasSize := strings.Cut(col.Type, "(")
			if hasSize {
				size, parseErr := strconv.ParseFloat(strings.TrimSuffix(tail, ")"), 64)
				if parseErr != nil {
					t.Fatal(parseErr)
				}
				row["DATA_TYPE"] = typ
				if typ == "NUMBER" {
					row["DATA_PRECISION"], row["DATA_SCALE"] = size, float64(0)
				} else {
					row["CHAR_LENGTH"] = size
				}
			}
			if col.Type == "TIMESTAMP" {
				row["DATA_TYPE"] = "TIMESTAMP(6)"
			}
			columnRows = append(columnRows, row)
		}
		constraintRows := make([]any, 0, len(step.Constraints))
		for i, con := range step.Constraints {
			own, ref := make([]any, 0, len(con.Columns)), make([]any, 0, len(con.ReferencedColumns))
			for _, col := range con.Columns {
				own = append(own, col)
			}
			for _, col := range con.ReferencedColumns {
				ref = append(ref, col)
			}
			constraintRows = append(constraintRows, map[string]any{
				"CONSTRAINT_NAME": step.Table + "_" + strconv.Itoa(i), "CONSTRAINT_TYPE": con.Type, "SEARCH_CONDITION_VC": con.Expression,
				"DELETE_RULE": con.DeleteRule, "STATUS": "ENABLED", "VALIDATED": "VALIDATED",
				"REFERENCED_TABLE": con.ReferencedTable, "REFERENCED_OWNER": "NEKO", "columns": own, "referencedColumns": ref,
			})
		}
		tables[step.Table] = map[string]any{"columns": columnRows, "constraints": constraintRows}
	}
	snapshot := map[string]any{
		"owner": map[string]any{"user": "NEKO", "schema": "NEKO"}, "ledgerPresent": false,
		"tables": tables, "sequences": sequences, "indexes": indexes,
	}
	return schemaFixtureConnector{snapshot, new([]string), new(int)}
}

type postPollFixtureConn struct {
	*testConn
	f               *postPollFixture
	txOpen          bool
	options         []string
	choices         []int64
	multiple        bool
	wrotePost       bool
	wroteBallot     bool
	visibilityCheck bool
}

func (f *postPollFixture) Connect(context.Context) (driver.Conn, error) {
	*f.connects++
	return &postPollFixtureConn{testConn: &testConn{&f.driverState}, f: f}, nil
}

func (c *postPollFixtureConn) Begin() (driver.Tx, error) {
	c.txOpen = true
	c.options = slices.Clone(c.f.options)
	c.choices = slices.Clone(c.f.choices)
	c.multiple = c.f.multiple
	c.wrotePost = false
	c.wroteBallot = false
	c.visibilityCheck = false
	return c, nil
}

func (c *postPollFixtureConn) Commit() error {
	c.f.commits++
	c.txOpen = false
	c.f.options, c.f.choices, c.f.multiple = c.options, c.choices, c.multiple
	c.f.hasBallot = c.f.hasBallot || c.wroteBallot
	return nil
}

func (c *postPollFixtureConn) Rollback() error {
	c.f.rollbacks++
	c.txOpen = false
	return nil
}

func (c *postPollFixtureConn) QueryContext(ctx context.Context, stmt string, args []driver.NamedValue) (driver.Rows, error) {
	f := c.f
	bind := func(key string) driver.Value { return directFixtureBind(args, key) }
	row := func(values ...driver.Value) (driver.Rows, error) { return &alertRows{values: values}, nil }
	empty := func() (driver.Rows, error) { return emptyRows{&f.driverState}, nil }
	switch stmt {
	case publishPolicy.SQL["lock"]:
		return row(int64(42))
	case publishPolicy.SQL["allowed"], canViewGroupContentSQL:
		return row(int64(1))
	case canPostGroupContentSQL:
		if f.denyGroupWrite {
			return row(int64(0))
		}
		return row(int64(1))
	case lockGroupContentSQL:
		return row(f.target.group)
	case "SELECT seq_post_id.NEXTVAL FROM dual", "SELECT seq_group_post_id.NEXTVAL AS id FROM dual":
		return row(f.target.post)
	case "SELECT seq_post_poll_id.NEXTVAL FROM dual":
		return row(int64(11))
	case visibleRegularPollPostSQL, visibleRegularPollPostSQL + " FOR UPDATE OF p.post_id":
		if f.hidden || bind("post_id") != f.target.post {
			return empty()
		}
		if stmt != visibleRegularPollPostSQL {
			c.visibilityCheck = true
		}
		return row(f.target.post)
	case groupContentPostsSQL:
		if f.hidden || bind("group_id") != f.target.group || !c.wrotePost && f.fail == "group post absent" {
			return empty()
		}
		c.visibilityCheck = c.txOpen
		return row(int64(1), int64(1), f.target.post, f.target.group, int64(42), "hello", nil, int64(0), int64(0),
			int64(0), int64(0), int64(0), nil, nil, int64(0))
	case publicProfileSQL:
		return row(int64(42), "owner", nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, "offline", nil, "self")
	case postPollsContract.SQL.Read:
		if f.legacy {
			return nil, errors.New("ORA-00942: table does not exist")
		}
		if f.fail == "bad column" {
			return nil, errors.New("ORA-00904: invalid identifier")
		}
		if (bind("is_group") == int64(1)) != (f.target.group != 0) || bind("post_id") != f.target.post {
			return nil, errors.New("poll read has wrong scope")
		}
		options, choices, multiple := f.options, f.choices, f.multiple
		ballot := f.hasBallot
		if c.txOpen {
			options, choices, multiple = c.options, c.choices, c.multiple
			ballot = ballot || c.wroteBallot
		}
		results := &schemaFixtureRows{columns: make([]string, 9)}
		for i, option := range options {
			id := int64(i + 1)
			total, count, selected := int64(0), int64(0), int64(0)
			if ballot {
				total = 1
			}
			if slices.Contains(choices, id) {
				count = 1
				if bind("viewer_id") == int64(42) {
					selected = 1
				}
			}
			results.values = append(results.values, []driver.Value{int64(11), postPollFixtureBool(multiple),
				"2026-12-01T03:22:33.987Z", postPollFixtureBool(f.closed), id, option, total, count, selected})
		}
		return results, nil
	case postPollsContract.SQL.AnyTablePresent:
		if f.fail == "unverified schema probe" {
			return nil, errors.New("metadata probe failed")
		}
		if len(f.snapshot["tables"].(map[string]any)) > 0 {
			return row(int64(1))
		}
		return empty()
	default:
		return (&schemaFixtureConn{f.schemaFixtureConnector}).QueryContext(ctx, stmt, args)
	}
}

func postPollFixtureBool(value bool) int64 {
	if value {
		return 1
	}
	return 0
}

func (c *postPollFixtureConn) ExecContext(_ context.Context, stmt string, args []driver.NamedValue) (driver.Result, error) {
	f := c.f
	bind := func(key string) driver.Value { return directFixtureBind(args, key) }
	if !c.txOpen {
		return nil, errors.New("poll write outside transaction")
	}
	switch stmt {
	case insertPostAtomicSQL, insertGroupPostSQL:
		c.wrotePost = true
	case postPollsContract.SQL.InsertPoll:
		postID, groupPostID := bind("post_id"), bind("group_post_id")
		wrongScope := f.target.group == 0 && (postID != f.target.post || groupPostID != nil) ||
			f.target.group != 0 && (groupPostID != f.target.post || postID != nil)
		if !c.wrotePost || wrongScope || bind("closes_at") != "2026-12-01T03:22:33.987Z" {
			return nil, errors.New("poll insert has wrong post or cutoff")
		}
		if f.fail == "past cutoff" {
			return driver.RowsAffected(0), nil
		}
		c.multiple = bind("allow_multiple") == int64(1)
	case postPollsContract.SQL.InsertOption:
		if f.fail == "second option" && len(c.options) == 1 {
			return nil, errors.New("second option insert failed")
		}
		if bind("poll_id") != int64(11) || bind("option_id") != int64(len(c.options)+1) {
			return nil, errors.New("incorrect option insert")
		}
		c.options = append(c.options, bind("option_text").(string))
	case postPollsContract.SQL.InsertBallot:
		if !c.visibilityCheck || bind("poll_id") != int64(11) || bind("user_id") != int64(42) {
			return nil, errors.New("incorrect ballot insert")
		}
		if f.hasBallot || f.fail == "unique conflict" {
			return nil, errors.New("ORA-00001: unique constraint violated")
		}
		if f.fail == "closed at insert" {
			return driver.RowsAffected(0), nil
		}
		c.wroteBallot = true
	case postPollsContract.SQL.InsertVote:
		if !c.wroteBallot || bind("poll_id") != int64(11) || bind("user_id") != int64(42) {
			return nil, errors.New("incorrect vote insert")
		}
		if f.fail == "second vote" && len(c.choices) == 1 {
			return nil, errors.New("second vote insert failed")
		}
		c.choices = append(c.choices, bind("option_id").(int64))
	default:
		return nil, errors.New("unexpected mutation")
	}
	return driver.RowsAffected(1), nil
}

func TestPostPollNativeCreationCommitsOrRollsBackPostAndOptions(t *testing.T) {
	poll := postPollCreation{
		options: []string{"first", "second"}, closesAt: time.Date(2026, 12, 1, 3, 22, 33, 987000000, time.UTC),
	}
	for _, target := range []postPollTarget{{post: 5}, {group: 7, post: 5}} {
		for _, tc := range []struct {
			fail string
			want error
		}{{"", nil}, {"past cutoff", errPostPollCutoff}, {"second option", errSessionStore}} {
			t.Run(strconv.FormatInt(target.group, 10)+"/"+tc.fail, func(t *testing.T) {
				ctx := context.Background()
				poll.multiple = target.group != 0
				f := newPostPollFixture(t, target)
				f.fail = tc.fail
				db := sql.OpenDB(f)
				defer db.Close()
				store := OracleSessions{db}
				var err error
				if target.group == 0 {
					_, err = store.CreatePostAtomic(ctx, 42, PostCreateInput{Content: "hello", Poll: &poll})
				} else {
					var result any
					result, err = store.WriteGroupPost(ctx, 42, groupPostMutation{action: "create", group: target.group, content: "hello", poll: &poll}, StorageURLPolicy{})
					if err == nil && result.(groupPost).Poll == nil {
						t.Fatal("the created group post omitted its poll")
					}
				}
				if !errors.Is(err, tc.want) {
					t.Fatalf("error %v, want %v", err, tc.want)
				}
				if tc.want != nil {
					if f.commits != 0 || f.rollbacks != 1 || len(f.options) != 0 {
						t.Fatalf("failing attachment left writes: commits %d, rollbacks %d, options %v", f.commits, f.rollbacks, f.options)
					}
					return
				}
				viewer := int64(42)
				persisted, err := store.GetPostPoll(ctx, &viewer, target)
				if err != nil || f.commits != 1 || f.rollbacks != 0 || !slices.Equal(f.options, poll.options) ||
					persisted.Multiple != poll.multiple || persisted.TotalBallots != 0 || persisted.Options[0].Percent != 0 {
					t.Fatalf("invalid round trip %+v, err %v, commits %d, options %v", persisted, err, f.commits, f.options)
				}
			})
		}
	}
}

func TestPostPollNativeVoteRemainsScopedAndAtomic(t *testing.T) {
	for _, tc := range []struct {
		name, fail             string
		options                []int64
		group, multiple        bool
		hidden, denied, closed bool
		want                   error
	}{
		{name: "single", options: []int64{1}},
		{name: "group multiple", options: []int64{2, 1}, group: true, multiple: true},
		{name: "hidden regular post", options: []int64{1}, hidden: true, want: errPostPollMissing},
		{name: "hidden group post", options: []int64{1}, group: true, hidden: true, want: errPostPollMissing},
		{name: "read-only group member", options: []int64{1}, group: true, denied: true, want: errPostPollForbidden},
		{name: "invalid single ballot", options: []int64{1, 2}, want: errPostPollInvalid},
		{name: "unknown option", options: []int64{3}, want: errPostPollInvalid},
		{name: "closed", options: []int64{1}, closed: true, want: errPostPollClosed},
		{name: "cutoff during submission", options: []int64{1}, fail: "closed at insert", want: errPostPollClosed},
		{name: "duplicate constraint", options: []int64{1}, fail: "unique conflict", want: errPostPollVoted},
		{name: "second vote fails", options: []int64{1, 2}, multiple: true, fail: "second vote", want: errSessionStore},
	} {
		t.Run(tc.name, func(t *testing.T) {
			target := postPollTarget{post: 5}
			if tc.group {
				target.group = 7
			}
			f := newPostPollFixture(t, target)
			f.options = []string{"first", "second"}
			f.multiple, f.closed, f.hidden, f.denyGroupWrite, f.fail = tc.multiple, tc.closed, tc.hidden, tc.denied, tc.fail
			db := sql.OpenDB(f)
			defer db.Close()
			ctx := context.Background()
			store := OracleSessions{db}
			poll, err := store.VotePostPoll(ctx, 42, target, tc.options)
			if !errors.Is(err, tc.want) {
				t.Fatalf("error %v, want %v", err, tc.want)
			}
			if tc.want != nil {
				if f.hasBallot || f.commits != 0 || f.rollbacks != 1 || len(f.choices) != 0 {
					t.Fatalf("rejected ballot persisted %+v", f.driverState)
				}
				return
			}
			wantChoices := slices.Clone(tc.options)
			slices.Sort(wantChoices)
			if f.commits != 1 || poll.TotalBallots != 1 || !slices.Equal(poll.MyOptionIDs, wantChoices) ||
				poll.Options[0].Percent != 100 || tc.multiple && poll.Options[1].Percent != 100 {
				t.Fatalf("invalid ballot receipt %+v, commits %d", poll, f.commits)
			}
			if _, err := store.VotePostPoll(ctx, 42, target, tc.options); !errors.Is(err, errPostPollVoted) || f.commits != 1 {
				t.Fatalf("repeat ballot error %v, commits %d", err, f.commits)
			}
			viewer := int64(15)
			other, err := store.GetPostPoll(ctx, &viewer, target)
			if err != nil || other.TotalBallots != 1 || other.MyOptionIDs == nil || len(other.MyOptionIDs) != 0 {
				t.Fatalf("unexpected other-viewer result %+v, error %v", other, err)
			}
		})
	}
}

func TestPostPollLegacyReadAndNativePreflight(t *testing.T) {
	ctx := context.Background()
	for _, state := range []string{"absent", "partial", "bad column", "different owner", "unverified schema probe"} {
		t.Run(state, func(t *testing.T) {
			target := postPollTarget{post: 5}
			f := newPostPollFixture(t, target)
			f.legacy, f.fail = state != "bad column", state
			tables := f.snapshot["tables"].(map[string]any)
			if state == "partial" || state == "bad column" {
				delete(tables, "N_POST_POLL_OPTIONS")
			} else {
				clear(tables)
			}
			if state == "different owner" {
				f.snapshot["owner"].(map[string]any)["schema"] = "OTHER"
			}
			db := sql.OpenDB(f)
			defer db.Close()
			store := OracleSessions{db}
			poll, err := store.ReadAttachedPostPoll(ctx, nil, target.post)
			if poll != nil || state == "absent" && err != nil || state != "absent" && !errors.Is(err, errPostPollUnavailable) {
				t.Fatalf("legacy poll %+v, error %v", poll, err)
			}
			if _, err := store.GetPostPoll(ctx, nil, target); !errors.Is(err, errPostPollUnavailable) {
				t.Fatalf("native read service status %v", err)
			}
			if _, err := store.VotePostPoll(ctx, 42, target, []int64{1}); !errors.Is(err, errPostPollUnavailable) {
				t.Fatalf("native vote service status %v", err)
			}
			if f.commits != 0 || f.rollbacks != 0 {
				t.Fatalf("unready preflight opened a transaction: %+v", f.driverState)
			}
			for _, stmt := range *f.calls {
				if !strings.HasPrefix(stmt, "SELECT ") {
					t.Fatalf("preflight attempted a mutation: %s", stmt)
				}
			}
		})
	}
}

type postPollHTTPRepository struct {
	OracleSessions
	sessions *memorySessions
}

func (r postPollHTTPRepository) Touch(ctx context.Context, claims auth.Claims) (int64, error) {
	return r.sessions.Touch(ctx, claims)
}

func TestPostPollNativeHTTPReceipt(t *testing.T) {
	codec, tokens := fixture(t)
	for _, tc := range []struct {
		path   string
		target postPollTarget
	}{
		{"/api/v2/posts/5/poll", postPollTarget{post: 5}},
		{"/api/v2/groups/7/posts/5/poll", postPollTarget{group: 7, post: 5}},
	} {
		t.Run(tc.path, func(t *testing.T) {
			f := newPostPollFixture(t, tc.target)
			f.options = []string{"first", "second"}
			db := sql.OpenDB(f)
			defer db.Close()
			handler := NewHandler(codec, postPollHTTPRepository{OracleSessions{db}, store()}, CorsPolicy{})
			request := func(method, suffix, body string, authorized bool, status int) *httptest.ResponseRecorder {
				t.Helper()
				r := httptest.NewRequest(method, tc.path+suffix, strings.NewReader(body))
				if authorized {
					r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
				}
				response := httptest.NewRecorder()
				handler.ServeHTTP(response, r)
				if response.Code != status || response.Header().Get("Cache-Control") != "private, no-store" {
					t.Fatalf("wanted status %d, got %d with response %s", status, response.Code, response.Body)
				}
				return response
			}
			request(http.MethodGet, "", "", tc.target.group != 0, 200)
			request(http.MethodPost, "/vote", `{"option_ids":[3]}`, true, 400)
			response := request(http.MethodPost, "/vote", `{"option_ids":[1]}`, true, 200)
			var envelope struct {
				Data postPoll `json:"data"`
			}
			if err := json.Unmarshal(response.Body.Bytes(), &envelope); err != nil || envelope.Data.TotalBallots != 1 ||
				!slices.Equal(envelope.Data.MyOptionIDs, []int64{1}) || envelope.Data.Options[0].Votes != 1 {
				t.Fatalf("invalid vote response %s", response.Body)
			}
			request(http.MethodPost, "/vote", `{"option_ids":[2]}`, true, 409)
			f.hidden = true
			request(http.MethodGet, "", "", tc.target.group != 0, 404)
		})
	}
}

func TestPostPollConcurrentSubmissionsKeepOneBallot(t *testing.T) {
	target := postPollTarget{post: 5}
	f := newPostPollFixture(t, target)
	f.options = []string{"first", "second"}
	db := sql.OpenDB(f)
	defer db.Close()
	// The isolated driver serializes connections. The native duplicate-key path is exercised separately.
	db.SetMaxOpenConns(1)
	store := OracleSessions{db}
	start := make(chan struct{})
	results := make(chan error, 2)
	for _, id := range []int64{1, 2} {
		go func() {
			<-start
			_, err := store.VotePostPoll(context.Background(), 42, target, []int64{id})
			results <- err
		}()
	}
	close(start)
	first, second := <-results, <-results
	if !(first == nil && errors.Is(second, errPostPollVoted) || second == nil && errors.Is(first, errPostPollVoted)) ||
		!f.hasBallot || len(f.choices) != 1 || f.commits != 1 || f.rollbacks != 1 {
		t.Fatalf("first error %v, second error %v, choices %v, commits %d, rollbacks %d", first, second, f.choices, f.commits, f.rollbacks)
	}
}
