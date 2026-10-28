package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

type readNotificationFixture struct {
	*memorySessions
	user, id    int64
	read        bool
	found, fail bool
	calls       int
}

type readRepoState struct {
	driverState
	affected              int64
	missing, queryFail    bool
	written               string
	bindings              []driver.NamedValue
	query                 string
	queryBindings         []driver.NamedValue
	execCalls, failExecAt int
}
type readRepoConnector struct{ state *readRepoState }
type readRepoConn struct {
	*testConn
	owner *readRepoState
}

func (c readRepoConnector) Connect(context.Context) (driver.Conn, error) {
	return &readRepoConn{&testConn{&c.state.driverState}, c.state}, nil
}
func (c readRepoConnector) Driver() driver.Driver { return testDriver{} }
func (c *readRepoConn) ExecContext(_ context.Context, q string, args []driver.NamedValue) (driver.Result, error) {
	c.owner.execCalls++
	if c.owner.failExecAt > 0 && c.owner.execCalls == c.owner.failExecAt {
		return nil, errors.New("private write error")
	}
	c.owner.written = q
	c.owner.bindings = args
	return driver.RowsAffected(c.owner.affected), nil
}
func (c *readRepoConn) QueryContext(_ context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	c.owner.query = q
	c.owner.queryBindings = args
	if c.owner.queryFail {
		return nil, errors.New("private error")
	}
	if c.owner.missing {
		return emptyRows{&c.owner.driverState}, nil
	}
	if strings.HasPrefix(q, "SELECT deleted_at ") {
		return &alertRows{values: []driver.Value{time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)}}, nil
	}
	return &alertRows{values: []driver.Value{int64(12), int64(1), time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)}}, nil
}
func TestNotificationReadRepositoryScopesUpdateAndRead(t *testing.T) {
	for _, tc := range []struct {
		name                 string
		affected             int64
		missing, fail, found bool
		commits              int
	}{{"owned", 1, false, false, true, 1}, {"not owned", 0, false, false, false, 1}, {"deleted after update", 1, true, false, false, 1}, {"read failure after commit", 1, false, true, false, 1}} {
		t.Run(tc.name, func(t *testing.T) {
			state := &readRepoState{affected: tc.affected, missing: tc.missing, queryFail: tc.fail}
			db := sql.OpenDB(readRepoConnector{state})
			defer db.Close()
			item, found, err := (OracleSessions{db}).SetNotificationRead(context.Background(), 42, 12, true)
			if found != tc.found || (err != nil) != tc.fail || state.commits != tc.commits {
				t.Fatal(item, found, err, state.commits)
			}
			if !strings.Contains(state.written, "user_id=:user_id") || !strings.Contains(state.written, "notification_id=:notification_id") {
				t.Fatal(state.written)
			}
			args := map[string]any{}
			for _, arg := range state.bindings {
				args[arg.Name] = arg.Value
			}
			if args["user_id"] != int64(42) || args["notification_id"] != int64(12) || args["is_read"] != int64(1) {
				t.Fatal(args)
			}
			if tc.affected > 0 && (!strings.Contains(state.query, "user_id=:user_id") || !strings.Contains(state.query, "notification_id=:notification_id")) {
				t.Fatal(state.query)
			}
			if found && (item.ReadAt == nil || *item.ReadAt != "2026-01-02T03:04:05.000Z") {
				t.Fatal(item)
			}
		})
	}
}

func (s *readNotificationFixture) SetNotificationRead(_ context.Context, user, id int64, read bool) (NotificationReadResult, bool, error) {
	s.calls++
	s.user, s.id, s.read = user, id, read
	if s.fail {
		return NotificationReadResult{}, false, errors.New("private db error")
	}
	if !s.found {
		return NotificationReadResult{}, false, nil
	}
	var date *string
	if read {
		value := "2026-01-02T03:04:05.000Z"
		date = &value
	}
	return NotificationReadResult{NotificationID: id, IsRead: int64(boolNumber(read)), ReadAt: date}, true, nil
}
func boolNumber(v bool) int {
	if v {
		return 1
	}
	return 0
}

func TestNotificationReadSharedBooleanVectors(t *testing.T) {
	bytes, err := os.ReadFile("../../contracts/scenarios/notification-single-read.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			ID       string `json:"id"`
			Value    any    `json:"value"`
			Expected bool   `json:"expected"`
		} `json:"cases"`
	}
	if json.Unmarshal(bytes, &fixture) != nil || len(fixture.Cases) != 11 {
		t.Fatal("invalid shared fixture")
	}
	for _, tc := range fixture.Cases {
		if got := readFlag(tc.Value); got != tc.Expected {
			t.Fatalf("%s: got %v", tc.ID, got)
		}
	}
}

func TestSingleNotificationReadRouteScopesIdentityAndPublishes(t *testing.T) {
	codec, tokens := fixture(t)
	for _, tc := range []struct {
		name, path, token, body, contentType string
		found, fail, publisherFail           bool
		status                               int
		read                                 bool
		events                               int
	}{
		{"unauthorized", "/api/v2/notifications/12/read-status", "", `{"is_read":true}`, "application/json", true, false, false, 401, false, 0},
		{"invalid id", "/api/v2/notifications/01/read-status", tokens["access-hs256"], `{"is_read":true}`, "application/json", true, false, false, 400, false, 0},
		{"bad body", "/api/v2/notifications/12/read-status", tokens["access-hs256"], `[]`, "application/json", true, false, false, 400, false, 0},
		{"not owned", "/api/v2/notifications/12/read-status", tokens["access-hs256"], `{"is_read":true}`, "application/json", false, false, false, 404, true, 0},
		{"failure", "/api/v2/notifications/12/read-status", tokens["access-hs256"], `{"is_read":true}`, "application/json", true, true, false, 500, true, 0},
		{"read", "/api/v2/notifications/12/read-status?user_id=99", tokens["access-hs256"], `{"is_read":true}`, "application/json", true, false, false, 200, true, 1},
		{"unread", "/api/v2/notifications/12/read-status", tokens["access-hs256"], `{"is_read":false}`, "application/json", true, false, false, 200, false, 1},
		{"form true", "/api/v2/notifications/12/read-status", tokens["access-hs256"], `is_read=YES`, "application/x-www-form-urlencoded", true, false, false, 200, true, 1},
		{"missing false", "/api/v2/notifications/12/read-status", tokens["access-hs256"], `{}`, "application/json", true, false, false, 200, false, 1},
		{"redis failure", "/api/v2/notifications/12/read-status", tokens["access-hs256"], `{"is_read":1}`, "application/json", true, false, true, 200, true, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := &readNotificationFixture{memorySessions: store(), found: tc.found, fail: tc.fail}
			pub := &likePublisher{fail: tc.publisherFail}
			h := NewHandlerWithConfig(codec, s, CorsPolicy{}, RefreshConfig{NotificationPublisher: pub})
			r := httptest.NewRequest("PUT", tc.path, strings.NewReader(tc.body))
			r.Header.Set("Content-Type", tc.contentType)
			if tc.token != "" {
				r.Header.Set("Authorization", "Bearer "+tc.token)
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			if w.Code != tc.status || strings.Contains(w.Body.String(), "private") || pub.calls != tc.events {
				t.Fatal(w.Code, w.Body.String(), pub.calls)
			}
			if tc.status == 200 {
				var body struct {
					Data struct {
						ID     int64   `json:"notification_id"`
						IsRead int64   `json:"is_read"`
						ReadAt *string `json:"read_at"`
					} `json:"data"`
				}
				if json.Unmarshal(w.Body.Bytes(), &body) != nil || body.Data.ID != 12 || body.Data.IsRead != int64(boolNumber(tc.read)) || s.user != 42 || s.id != 12 || s.read != tc.read {
					t.Fatal(w.Body.String(), s)
				}
				if pub.user != 42 || pub.kind != "notification_read_status_updated" || pub.data["notification_id"] != int64(12) {
					t.Fatal(pub)
				}
			}
		})
	}
}
