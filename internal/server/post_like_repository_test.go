package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestAddLikeRepositoryBindsVisibilityAndCount(t *testing.T) {
	for _, tc := range []struct {
		name              string
		visibility        []bool
		affected          int64
		visible, inserted bool
		count             float64
	}{
		{"first", []bool{true}, 1, true, true, 3},
		{"duplicate", []bool{true, true}, 0, true, false, 3},
		{"hidden", []bool{false}, 0, false, false, 0},
		{"lost visibility", []bool{true, false}, 0, false, false, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			state := &unlikeState{visibility: tc.visibility, affected: tc.affected}
			db := sql.OpenDB(unlikeConnector{state})
			defer db.Close()
			count, inserted, visible, err := (OracleSessions{db}).AddPostLike(context.Background(), 42, 1)
			if err != nil || count != tc.count || inserted != tc.inserted || visible != tc.visible {
				t.Fatalf("%v %v %v %v", count, inserted, visible, err)
			}
			if state.write != "" && (!strings.Contains(state.write, "fn_can_view_post(:user_id,:post_id)=1") || !strings.Contains(state.write, "NOT EXISTS") || len(state.args) != 2 || state.args[0].Value != int64(1) || state.args[1].Value != int64(42)) {
				t.Fatal(state.write, state.args)
			}
		})
	}
}

type likeEndToEndState struct {
	driverState
	inserted         int64
	failNotification bool
	writes           []string
}
type likeEndToEndConnector struct{ state *likeEndToEndState }
type likeEndToEndConn struct {
	*testConn
	owner *likeEndToEndState
}

func (c likeEndToEndConnector) Connect(context.Context) (driver.Conn, error) {
	return &likeEndToEndConn{&testConn{&c.state.driverState}, c.state}, nil
}
func (c likeEndToEndConnector) Driver() driver.Driver { return testDriver{} }
func (c *likeEndToEndConn) ExecContext(_ context.Context, q string, args []driver.NamedValue) (driver.Result, error) {
	c.owner.writes = append(c.owner.writes, q)
	if strings.Contains(q, "INSERT INTO n_notifications") && c.owner.failNotification {
		return nil, errors.New("private notification failure")
	}
	if strings.Contains(q, "INSERT INTO n_post_likes") {
		return driver.RowsAffected(c.owner.inserted), nil
	}
	return driver.RowsAffected(1), nil
}
func (c *likeEndToEndConn) QueryContext(_ context.Context, q string, _ []driver.NamedValue) (driver.Rows, error) {
	switch {
	case strings.Contains(q, "FROM n_posts p WHERE"):
		return &alertRows{values: []driver.Value{int64(1)}}, nil
	case strings.Contains(q, "SELECT likes_count FROM n_post_stats"):
		return &alertRows{values: []driver.Value{int64(3)}}, nil
	case strings.Contains(q, "SELECT author_id FROM n_posts"):
		return &alertRows{values: []driver.Value{int64(9)}}, nil
	case strings.Contains(q, "SELECT COALESCE(display_name,username)"):
		return &alertRows{values: []driver.Value{"小猫"}}, nil
	case strings.Contains(q, "SELECT DBMS_LOB.SUBSTR(content"):
		return &alertRows{values: []driver.Value{" hello  world "}}, nil
	case strings.Contains(q, "NVL(us.push_notification_enabled"):
		return &alertRows{values: []driver.Value{int64(1), int64(1)}}, nil
	case strings.Contains(q, "seq_notification_id.NEXTVAL"):
		return &alertRows{values: []driver.Value{int64(44)}}, nil
	case strings.Contains(q, "FROM n_notifications WHERE user_id=:user_id AND notification_id=:notification_id"):
		return &alertRows{values: []driver.Value{int64(44), int64(42), "like", "小猫 赞了你的推文", "你的推文收到了一次点赞。", "post", int64(1), "normal", int64(0), nil, nil, `{"event":"post_like","post_excerpt":"hello world","target_post_id":1}`, time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)}}, nil
	case strings.Contains(q, "FROM v_user_profile_public"):
		return &alertRows{values: []driver.Value{int64(42), "actor", "", "小猫", "", "", "", int64(0), int64(0), int64(0), int64(0), int64(0), "offline", nil, "none"}}, nil
	default:
		return nil, errors.New("unexpected query")
	}
}

func TestLikeRouteThroughOracleRepositoryAndPublisher(t *testing.T) {
	codec, tokens := fixture(t)
	for _, tc := range []struct {
		name                    string
		inserted                int64
		failNotification        bool
		status, events, commits int
	}{
		{"new like", 1, false, 200, 1, 3},
		{"duplicate", 0, false, 200, 0, 2},
		{"notification failure after like commit", 1, true, 500, 0, 2},
	} {
		t.Run(tc.name, func(t *testing.T) {
			state := &likeEndToEndState{inserted: tc.inserted, failNotification: tc.failNotification}
			db := sql.OpenDB(likeEndToEndConnector{state})
			defer db.Close()
			publisher := &likePublisher{}
			handler := NewHandlerWithConfig(codec, OracleSessions{db}, CorsPolicy{}, RefreshConfig{NotificationPublisher: publisher})
			request := httptest.NewRequest("POST", "/api/v2/posts/1/likes", nil)
			request.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, request)
			if response.Code != tc.status || publisher.calls != tc.events || state.commits != tc.commits || strings.Contains(response.Body.String(), "private") {
				t.Fatal(response.Code, response.Body.String(), publisher.calls, state.commits, state.writes)
			}
			if tc.events == 1 {
				item := publisher.data["notification"].(NotificationItem)
				if publisher.user != 9 || item.ID != 44 || item.Actor == nil || item.Actor.UserID != 42 || item.Metadata.(map[string]any)["post_excerpt"] != "hello world" {
					t.Fatal(item)
				}
			}
		})
	}
}

type likeNotificationState struct {
	alertState
	author             int64
	missingAuthor      bool
	actorName, content string
	failStage          string
}
type likeNotificationConnector struct{ state *likeNotificationState }
type likeNotificationConn struct {
	*alertConn
	state *likeNotificationState
}

func (c likeNotificationConnector) Connect(context.Context) (driver.Conn, error) {
	return &likeNotificationConn{&alertConn{testConn: &testConn{state: &c.state.driverState}, state: &c.state.alertState}, c.state}, nil
}
func (c likeNotificationConnector) Driver() driver.Driver { return testDriver{} }
func (c *likeNotificationConn) QueryContext(ctx context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	s := c.state
	switch {
	case strings.Contains(q, "SELECT author_id FROM n_posts"):
		if s.failStage == "author" {
			return nil, errors.New("private author")
		}
		if s.missingAuthor {
			return emptyRows{&s.driverState}, nil
		}
		return &alertRows{values: []driver.Value{s.author}}, nil
	case strings.Contains(q, "SELECT COALESCE(display_name,username)"):
		if s.failStage == "name" {
			return nil, errors.New("private name")
		}
		return &alertRows{values: []driver.Value{s.actorName}}, nil
	case strings.Contains(q, "SELECT DBMS_LOB.SUBSTR(content"):
		if s.failStage == "excerpt" {
			return nil, errors.New("private excerpt")
		}
		return &alertRows{values: []driver.Value{s.content}}, nil
	default:
		return c.alertConn.QueryContext(ctx, q, args)
	}
}

func TestPrepareLikeNotificationHonorsPreferencesAndMetadata(t *testing.T) {
	for _, tc := range []struct {
		name                  string
		author, push, enabled int64
		missing               bool
		fail                  string
		stored, canPush       bool
	}{
		{"enabled", 9, 1, 1, false, "", true, true},
		{"push disabled", 9, 0, 1, false, "", true, false},
		{"type disabled", 9, 1, 0, false, "", false, false},
		{"self", 42, 1, 1, false, "", false, false},
		{"missing", 9, 1, 1, true, "", false, false},
		{"failed name", 9, 1, 1, false, "name", false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			state := &likeNotificationState{alertState: alertState{push: tc.push, enabled: tc.enabled}, author: tc.author, missingAuthor: tc.missing, actorName: "小猫", content: "  hello\n  world  ", failStage: tc.fail}
			db := sql.OpenDB(likeNotificationConnector{state})
			defer db.Close()
			user, stored, err := (OracleSessions{db}).PreparePostLikeNotification(context.Background(), 42, 1)
			if (err != nil) != (tc.fail != "") || (stored != nil) != tc.stored || (state.commits == 1) != tc.stored {
				t.Fatalf("%d %+v %v commits=%d", user, stored, err, state.commits)
			}
			if stored != nil {
				if user != 9 || stored.ID != 44 || stored.PushEnabled != tc.canPush {
					t.Fatal(user, stored)
				}
				args := map[string]any{}
				for _, arg := range state.args {
					args[arg.Name] = arg.Value
				}
				if args["user_id"] != int64(9) || args["actor_id"] != int64(42) || args["title"] != "小猫 赞了你的推文" || args["resource_id"] != int64(1) {
					t.Fatal(args)
				}
				var metadata map[string]any
				if json.Unmarshal([]byte(args["metadata_json"].(string)), &metadata) != nil || metadata["post_excerpt"] != "hello world" || metadata["event"] != "post_like" || metadata["target_post_id"] != float64(1) {
					t.Fatal(metadata)
				}
			}
		})
	}
}

func TestPostLikeExcerptMatchesJavaScriptUTF16AndWhitespace(t *testing.T) {
	for _, tc := range []struct {
		input sql.NullString
		want  string
	}{
		{sql.NullString{}, `null`},
		{sql.NullString{String: "", Valid: true}, `null`},
		{sql.NullString{String: " \u00a0 \n", Valid: true}, `""`},
		{sql.NullString{String: " a\u00a0 b ", Valid: true}, `"a b"`},
		{sql.NullString{String: strings.Repeat("a", 159) + "😀suffix", Valid: true}, `"` + strings.Repeat("a", 159) + `\ud83d..."`},
		{sql.NullString{String: strings.Repeat("😀", 80) + "x", Valid: true}, `"` + strings.Repeat("😀", 80) + `..."`},
	} {
		if got := string(postLikeExcerpt(tc.input)); got != tc.want {
			t.Fatalf("got %s want %s", got, tc.want)
		}
	}
}
