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

type preferenceFixture struct {
	state                         driverState
	missing, denied, failReadback bool
	writes                        int
}

type preferenceConn struct {
	*testConn
	fixture *preferenceFixture
}

func (*preferenceFixture) Driver() driver.Driver { return testDriver{} }
func (f *preferenceFixture) Connect(context.Context) (driver.Conn, error) {
	return &preferenceConn{&testConn{&f.state}, f}, nil
}

func (c *preferenceConn) QueryContext(_ context.Context, stmt string, _ []driver.NamedValue) (driver.Rows, error) {
	switch stmt {
	case lockGroupContentSQL:
		return &alertRows{values: []driver.Value{int64(7)}, done: c.fixture.missing}, nil
	case groupPreferenceSQL:
		var member driver.Value = int64(42)
		if c.fixture.denied {
			member = nil
		}
		flag := int64(1)
		if c.fixture.writes != 0 && !c.fixture.failReadback {
			flag = 0
		}
		return &alertRows{values: []driver.Value{int64(7), member, flag, nil}}, nil
	default:
		return nil, errors.New("unexpected query")
	}
}

func (c *preferenceConn) ExecContext(_ context.Context, stmt string, _ []driver.NamedValue) (driver.Result, error) {
	if stmt != saveGroupPreferenceSQL {
		return nil, errors.New("unexpected update")
	}
	c.fixture.writes++
	return driver.RowsAffected(1), nil
}

func TestGroupPreferenceWritesAreAtomic(t *testing.T) {
	for _, tc := range []struct {
		name                          string
		missing, denied, failReadback bool
		writes, commits               int
	}{
		{"saved", false, false, false, 1, 1},
		{"missing", true, false, false, 0, 0},
		{"non-member", false, true, false, 0, 0},
		{"readback failed", false, false, true, 1, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := &preferenceFixture{missing: tc.missing, denied: tc.denied, failReadback: tc.failReadback}
			db := sql.OpenDB(f)
			defer db.Close()
			enabled := false
			result, err := (OracleSessions{DB: db}).GroupNotificationPreference(context.Background(), 42, 7, &enabled)
			if (err == nil) != (tc.commits == 1) || f.writes != tc.writes || f.state.commits != tc.commits || f.state.rollbacks != 1-tc.commits {
				t.Fatalf("result=%+v err=%v writes=%d state=%+v", result, err, f.writes, f.state)
			}
			if err == nil && (result.GroupID != 7 || result.UserID != 42 || result.Enabled) {
				t.Fatalf("result=%+v", result)
			}
		})
	}
}

func (groupDetailFixture) GroupNotificationPreference(_ context.Context, viewer, group int64, enabled *bool) (groupPreference, error) {
	if group != 7 {
		return groupPreference{}, errGroupDetailMissing
	}
	return groupPreference{UserID: viewer, GroupID: group, Enabled: enabled == nil || *enabled}, nil
}

func (groupDetailFixture) GroupAuditLogs(_ context.Context, viewer, group int64, page SessionPage, _ StorageURLPolicy) ([]groupAuditItem, int64, error) {
	if group != 7 || viewer != 42 {
		return nil, 0, &groupMembershipFailure{422, "无权查看审计日志"}
	}
	if page.Start > 1 {
		return []groupAuditItem{}, 2, nil
	}
	return []groupAuditItem{{ID: 2, GroupID: group, ActorID: 20, Action: "change_role"}}, 2, nil
}

func TestGroupAdministrationRoutes(t *testing.T) {
	codec, tokens := fixture(t)
	app := NewHandler(codec, groupDetailFixture{store()}, CorsPolicy{})
	for _, tc := range []struct {
		method, path, body, want string
		status                   int
	}{
		{"GET", "/7/notification-preference", "", `"is_enabled":true`, 200},
		{"PUT", "/7/notification-preference", `{"is_enabled":false}`, `"is_enabled":false`, 200},
		{"PUT", "/7/notification-preference", `{"is_enabled":1}`, `"is_enabled":true`, 200},
		{"PUT", "/7/notification-preference", `[]`, "请求体必须是 JSON 对象", 400},
		{"GET", "/8/notification-preference", "", "群组不存在", 404},
		{"GET", "/7/audit-logs", "", `"actor_id":20,"actor":null`, 200},
		{"GET", "/7/audit-logs?page=2", "", `"total":2`, 200},
		{"GET", "/8/audit-logs", "", "无权查看审计日志", 422},
	} {
		req := httptest.NewRequest(tc.method, "/api/v2/groups"+tc.path, strings.NewReader(tc.body))
		req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		w := httptest.NewRecorder()
		app.ServeHTTP(w, req)
		if w.Code != tc.status || !strings.Contains(w.Body.String(), tc.want) || w.Header().Get("Cache-Control") != "private, no-store" {
			t.Fatalf("%s %s: %d %s", tc.method, tc.path, w.Code, w.Body)
		}
	}
}
