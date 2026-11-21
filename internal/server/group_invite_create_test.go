package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"testing"
)

func TestGroupInviteBoundsAndDefaults(t *testing.T) {
	for _, raw := range []string{`[]`, `{"max_uses":0}`, `{"max_uses":100000}`, `{"expire_hours":8761}`, `{"expire_hours":2.5}`, `{"invitee_id":"8"}`, `{"message":1}`} {
		if _, bad := parseGroupInviteInput([]byte(raw)); bad == "" {
			t.Errorf("accepted %s", raw)
		}
	}
	link, bad := parseGroupInviteInput([]byte(`{}`))
	if bad != "" || link.Target != nil || link.Hours != 168 || link.MaxUses != 1 {
		t.Fatalf("defaults %+v %s", link, bad)
	}
	directed, bad := parseGroupInviteInput([]byte(`{"invitee_id":9,"max_uses":5}`))
	if bad != "" || directed.Target == nil || *directed.Target != 9 || directed.MaxUses != 1 {
		t.Fatalf("directed %+v %s", directed, bad)
	}
}

type groupInviteCreateFixture struct {
	state              driverState
	optOut, failNotice bool
	writes             []string
}
type groupInviteCreateConn struct {
	*testConn
	f *groupInviteCreateFixture
}

func (*groupInviteCreateFixture) Driver() driver.Driver { return testDriver{} }
func (f *groupInviteCreateFixture) Connect(context.Context) (driver.Conn, error) {
	return &groupInviteCreateConn{&testConn{&f.state}, f}, nil
}

func (c *groupInviteCreateConn) QueryContext(_ context.Context, stmt string, args []driver.NamedValue) (driver.Rows, error) {
	result := func(values ...driver.Value) (driver.Rows, error) { return &alertRows{values: values}, nil }
	switch stmt {
	case membershipGroupSQL:
		return result(int64(42), "public", int64(0), int64(1), int64(0))
	case membershipReadSQL:
		if args[1].Value == int64(42) {
			return result("owner", "active")
		}
		return &alertRows{values: []driver.Value{"member", "active"}, done: true}, nil
	case groupInviteTargetSQL:
		return result(int64(9))
	case "SELECT seq_group_invite_id.NEXTVAL FROM dual":
		return result(int64(12))
	case groupInviteExpirySQL:
		return result("2026-11-17T12:00:00.000Z")
	case groupInvitePreferenceSQL:
		if c.f.optOut {
			return result(int64(0))
		}
		return result(int64(1))
	case groupInviteNamesSQL:
		return result("Cat", "Owner")
	case notificationDeliverySQL:
		return result(int64(1), int64(1))
	case "SELECT seq_notification_id.NEXTVAL FROM dual":
		return result(int64(13))
	default:
		return nil, errors.New("unexpected query")
	}
}

func (c *groupInviteCreateConn) ExecContext(_ context.Context, stmt string, _ []driver.NamedValue) (driver.Result, error) {
	c.f.writes = append(c.f.writes, stmt)
	if c.f.failNotice && stmt == insertNotificationSQL {
		return driver.RowsAffected(0), nil
	}
	return driver.RowsAffected(1), nil
}

func TestGroupInviteAndNoticeCommitTogether(t *testing.T) {
	for _, tc := range []struct {
		name, body         string
		optOut, failNotice bool
		writes, commits    int
	}{
		{"link", `{}`, false, false, 1, 1},
		{"directed", `{"invitee_id":9}`, false, false, 2, 1},
		{"opt out", `{"invitee_id":9}`, true, false, 1, 1},
		{"notice fails", `{"invitee_id":9}`, false, true, 2, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := &groupInviteCreateFixture{optOut: tc.optOut, failNotice: tc.failNotice}
			db := sql.OpenDB(f)
			defer db.Close()
			in, _ := parseGroupInviteInput([]byte(tc.body))
			out, err := (OracleSessions{DB: db}).CreateGroupInvite(context.Background(), 42, 7, in)
			if (err != nil) != tc.failNotice || f.state.commits != tc.commits ||
				f.state.rollbacks != 1-tc.commits || len(f.writes) != tc.writes {
				t.Fatalf("commits=%d rollbacks=%d writes=%q error=%v", f.state.commits, f.state.rollbacks, f.writes, err)
			}
			if err == nil && in.Target == nil && (out.Code == nil || out.URL == nil || len(*out.Code) != 32 || !groupInviteCodePattern.MatchString(*out.Code)) {
				t.Fatalf("link shape: %+v", out)
			}
			if err == nil && in.Target != nil && (out.Code != nil || out.URL != nil || (out.notice != nil) == tc.optOut) {
				t.Fatalf("directed invite shape: %+v", out)
			}
		})
	}
}
