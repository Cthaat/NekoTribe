package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"testing"
)

type membershipConnector struct {
	state                driverState
	status               string
	expired, insertFails bool
	locked               bool
	writes               []string
}

type membershipConn struct {
	*testConn
	fixture *membershipConnector
}

func (*membershipConnector) Driver() driver.Driver { return testDriver{} }
func (c *membershipConnector) Connect(context.Context) (driver.Conn, error) {
	return &membershipConn{&testConn{&c.state}, c}, nil
}

func (c *membershipConn) QueryContext(_ context.Context, query string, _ []driver.NamedValue) (driver.Rows, error) {
	switch query {
	case membershipGroupSQL:
		c.fixture.locked = true
		return &alertRows{values: []driver.Value{int64(9), "secret", int64(1), int64(1), int64(0)}}, nil
	case membershipReadSQL:
		if !c.fixture.locked {
			return nil, errors.New("group not locked")
		}
		return &alertRows{values: []driver.Value{"member", c.fixture.status}, done: c.fixture.status == ""}, nil
	case membershipInviteSQL:
		return &alertRows{values: []driver.Value{int64(15), int64(9)}}, nil
	case "SELECT seq_group_member_id.NEXTVAL FROM dual":
		return &alertRows{values: []driver.Value{int64(8)}}, nil
	default:
		return nil, errors.New("unexpected query")
	}
}

func (c *membershipConn) ExecContext(_ context.Context, query string, _ []driver.NamedValue) (driver.Result, error) {
	c.fixture.writes = append(c.fixture.writes, query)
	if query == membershipConsumeSQL && c.fixture.expired {
		return driver.RowsAffected(0), nil
	}
	if query == membershipInsertSQL && c.fixture.insertFails {
		return nil, errors.New("insert failed")
	}
	return driver.RowsAffected(1), nil
}

func TestGroupMembershipCommitsInvitationAndInsertTogether(t *testing.T) {
	for _, tc := range []struct {
		name                        string
		join                        bool
		status                      string
		expired, insertFails        bool
		wantStatus, commits, writes int
	}{
		{"join", true, "", false, false, 200, 1, 2},
		{"member insert failure", true, "", false, true, 500, 0, 2},
		{"invite expired at update", true, "", true, false, 422, 0, 1},
		{"duplicate member", true, "pending", false, false, 422, 0, 0},
		{"banned member cannot discard ban", false, "banned", false, false, 422, 0, 0},
		{"cancel pending membership", false, "pending", false, false, 200, 1, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := &membershipConnector{status: tc.status, expired: tc.expired, insertFails: tc.insertFails}
			db := sql.OpenDB(f)
			defer db.Close()
			result, err := (OracleSessions{DB: db}).ChangeGroupMembership(context.Background(), 42, 7, tc.join, "AB12")
			status := 200
			var failure *groupMembershipFailure
			if errors.As(err, &failure) {
				status = failure.status
			} else if err != nil {
				status = 500
			}
			if status != tc.wantStatus || f.state.commits != tc.commits || f.state.rollbacks != 1-tc.commits || len(f.writes) != tc.writes {
				t.Fatalf("status=%d commits=%d rollbacks=%d writes=%d err=%v", status, f.state.commits, f.state.rollbacks, len(f.writes), err)
			}
			if tc.join && err == nil && (result.Status != "active" || f.writes[0] != membershipConsumeSQL || f.writes[1] != membershipInsertSQL) {
				t.Fatalf("unexpected join: %+v", result)
			}
		})
	}
}
