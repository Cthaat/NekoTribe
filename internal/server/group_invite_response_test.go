package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type inviteInboxFixture struct {
	*memorySessions
	directedInviteStore
	inviteID int64
}

func (f *inviteInboxFixture) MyGroupInvites(_ context.Context, viewer, inviteID int64, _ SessionPage, _ StorageURLPolicy) ([]groupInviteItem, int64, error) {
	if viewer != 42 {
		return nil, 0, errSessionStore
	}
	f.inviteID = inviteID
	return []groupInviteItem{}, 0, nil
}

func TestDirectedInviteInboxFilter(t *testing.T) {
	codec, tokens := fixture(t)
	repository := &inviteInboxFixture{memorySessions: store()}
	app := NewHandlerWithConfig(codec, repository, CorsPolicy{}, RefreshConfig{})
	for _, tc := range []struct {
		query  string
		status int
		id     int64
	}{
		{"", 200, 0},
		{"?invite_id=12", 200, 12},
		{"?invite_id=012", 400, -1},
		{"?invite_id=12&invite_id=12", 400, -1},
		{"?invite_id=9007199254740992", 400, -1},
	} {
		repository.inviteID = -1
		req := httptest.NewRequest(http.MethodGet, "/api/v2/users/me/group-invites"+tc.query, nil)
		req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		res := httptest.NewRecorder()
		app.ServeHTTP(res, req)
		if res.Code != tc.status || repository.inviteID != tc.id || res.Header().Get("Cache-Control") != "private, no-store" {
			t.Fatalf("%s: status=%d id=%d body=%s", tc.query, res.Code, repository.inviteID, res.Body)
		}
		if tc.status == 400 && !strings.Contains(res.Body.String(), "invite_id 参数错误") {
			t.Fatal(res.Body.String())
		}
	}
}

type inviteResponseFixture struct {
	state                                         driverState
	missing, expired, member, changed, failInsert bool
	writes                                        int
}
type inviteResponseConn struct {
	*testConn
	f *inviteResponseFixture
}

func (*inviteResponseFixture) Driver() driver.Driver { return testDriver{} }
func (f *inviteResponseFixture) Connect(context.Context) (driver.Conn, error) {
	return &inviteResponseConn{&testConn{&f.state}, f}, nil
}

func (c *inviteResponseConn) QueryContext(_ context.Context, stmt string, _ []driver.NamedValue) (driver.Rows, error) {
	switch stmt {
	case directedInviteLookupSQL:
		return &alertRows{values: []driver.Value{int64(7)}, done: c.f.missing}, nil
	case membershipGroupSQL:
		return &alertRows{values: []driver.Value{int64(9), "private", int64(1), int64(1), int64(0)}}, nil
	case directedInviteLockSQL:
		return &alertRows{values: []driver.Value{int64(9)}, done: c.f.expired}, nil
	case membershipReadSQL:
		return &alertRows{values: []driver.Value{"member", "banned"}, done: !c.f.member}, nil
	case "SELECT seq_group_member_id.NEXTVAL FROM dual":
		return &alertRows{values: []driver.Value{int64(12)}}, nil
	default:
		return nil, errors.New("unexpected query")
	}
}

func (c *inviteResponseConn) ExecContext(_ context.Context, stmt string, _ []driver.NamedValue) (driver.Result, error) {
	c.f.writes++
	if stmt == directedInviteWriteSQL && c.f.changed || stmt == membershipInsertSQL && c.f.failInsert {
		return driver.RowsAffected(0), nil
	}
	return driver.RowsAffected(1), nil
}

func TestDirectedInviteTransaction(t *testing.T) {
	for _, tc := range []struct {
		name                                                  string
		accept, missing, expired, member, changed, failInsert bool
		status, writes                                        int
	}{
		{"accept", true, false, false, false, false, false, 200, 2},
		{"decline existing membership", false, false, false, true, false, false, 200, 1},
		{"other recipient", true, true, false, false, false, false, 404, 0},
		{"expired", true, false, true, false, false, false, 422, 0},
		{"existing membership", true, false, false, true, false, false, 422, 0},
		{"state changed before update", false, false, false, false, true, false, 422, 1},
		{"insert rollback", true, false, false, false, false, true, 500, 2},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := &inviteResponseFixture{missing: tc.missing, expired: tc.expired, member: tc.member, changed: tc.changed, failInsert: tc.failInsert}
			db := sql.OpenDB(f)
			defer db.Close()
			out, err := (OracleSessions{DB: db}).RespondGroupInvite(context.Background(), 42, 10, tc.accept)
			status, commit := 200, 1
			var failure *groupMembershipFailure
			if errors.As(err, &failure) {
				status, commit = failure.status, 0
			} else if err != nil {
				status, commit = 500, 0
			}
			if status != tc.status || f.state.commits != commit || f.state.rollbacks != 1-commit || f.writes != tc.writes {
				t.Fatalf("commits=%d rollbacks=%d writes=%d status=%d err=%v", f.state.commits, f.state.rollbacks, f.writes, status, err)
			}
			if err == nil && (out.InviteID != 10 || out.GroupID != 7 || (out.Status == "accepted") != tc.accept) {
				t.Fatalf("response=%+v", out)
			}
		})
	}
}

func TestDirectedInviteDecisionRejectsAmbiguity(t *testing.T) {
	for _, raw := range []string{`{}`, `{"accept":null}`, `{"accept":true,"action":"accept"}`, `{"action":"unknown"}`} {
		if _, ok := directedInviteDecision([]byte(raw)); ok {
			t.Errorf("accepted %s", raw)
		}
	}
	if accept, ok := directedInviteDecision([]byte(`{"action":"decline"}`)); accept || !ok {
		t.Fatal("legacy decline was not recognized")
	}
}
