package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"reflect"
	"testing"
)

type ownershipFixture struct {
	state                   driverState
	owner                   int64
	inactive, deleted       bool
	actorRole, targetStatus string
	failWrite               int
	writes                  []string
}

type ownershipConn struct {
	*testConn
	fixture *ownershipFixture
}

func (*ownershipFixture) Driver() driver.Driver { return testDriver{} }

func (f *ownershipFixture) Connect(context.Context) (driver.Conn, error) {
	return &ownershipConn{&testConn{&f.state}, f}, nil
}

func (c *ownershipConn) QueryContext(_ context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	switch query {
	case membershipGroupSQL:
		active, deleted := int64(1), int64(0)
		if c.fixture.inactive {
			active = 0
		}
		if c.fixture.deleted {
			deleted = 1
		}
		return &alertRows{values: []driver.Value{c.fixture.owner, "public", int64(0), active, deleted}}, nil
	case membershipReadSQL:
		if args[1].Value == int64(42) {
			return &alertRows{values: []driver.Value{c.fixture.actorRole, "active"}}, nil
		}
		return &alertRows{values: []driver.Value{"member", c.fixture.targetStatus}, done: c.fixture.targetStatus == ""}, nil
	default:
		return nil, errors.New("unexpected query")
	}
}

func TestGroupDissolutionIsAtomic(t *testing.T) {
	for _, tc := range []struct {
		name              string
		owner             int64
		role              string
		inactive, deleted bool
		failWrite, status int
	}{
		{"owner", 42, "owner", false, false, 0, 200},
		{"inactive group", 42, "owner", true, false, 0, 200},
		{"already dissolved", 42, "owner", true, true, 0, 404},
		{"other owner", 9, "owner", false, false, 0, 422},
		{"admin", 42, "admin", false, false, 0, 422},
		{"group update fails", 42, "owner", false, false, 1, 500},
		{"audit fails", 42, "owner", false, false, 2, 500},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := &ownershipFixture{owner: tc.owner, actorRole: tc.role, inactive: tc.inactive, deleted: tc.deleted, failWrite: tc.failWrite}
			db := sql.OpenDB(f)
			defer db.Close()
			err := (OracleSessions{DB: db}).DissolveGroup(context.Background(), 42, 7)
			status, commits, writes := 200, 0, tc.failWrite
			var failure *groupMembershipFailure
			if errors.As(err, &failure) {
				status = failure.status
			} else if err != nil {
				status = 500
			}
			if tc.status == 200 {
				commits, writes = 1, 2
			}
			if status != tc.status || f.state.commits != commits || f.state.rollbacks != 1-commits || len(f.writes) != writes {
				t.Fatalf("status=%d commits=%d rollbacks=%d writes=%v err=%v", status, f.state.commits, f.state.rollbacks, f.writes, err)
			}
			for i, query := range f.writes {
				if query != []string{dissolveGroupSQL, dissolveGroupAuditSQL}[i] {
					t.Fatalf("write order: %v", f.writes)
				}
			}
		})
	}
}

func (c *ownershipConn) ExecContext(_ context.Context, query string, _ []driver.NamedValue) (driver.Result, error) {
	c.fixture.writes = append(c.fixture.writes, query)
	if len(c.fixture.writes) == c.fixture.failWrite {
		return driver.RowsAffected(0), nil
	}
	return driver.RowsAffected(1), nil
}

func TestGroupOwnershipIsAtomic(t *testing.T) {
	for _, tc := range []struct {
		name                    string
		owner, target           int64
		actorRole, targetStatus string
		failWrite, want         int
	}{
		{"transfer", 42, 9, "owner", "active", 0, 200},
		{"former owner", 9, 8, "admin", "active", 0, 422},
		{"owner row inconsistent", 42, 9, "admin", "active", 0, 422},
		{"self", 42, 42, "owner", "active", 0, 422},
		{"pending", 42, 9, "owner", "pending", 0, 422},
		{"missing", 42, 9, "owner", "", 0, 404},
		{"demotion fails", 42, 9, "owner", "active", 1, 500},
		{"promotion fails", 42, 9, "owner", "active", 2, 500},
		{"group update fails", 42, 9, "owner", "active", 3, 500},
		{"audit fails", 42, 9, "owner", "active", 4, 500},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := &ownershipFixture{owner: tc.owner, actorRole: tc.actorRole, targetStatus: tc.targetStatus, failWrite: tc.failWrite}
			db := sql.OpenDB(f)
			defer db.Close()
			err := (OracleSessions{DB: db}).TransferGroupOwnership(context.Background(), 42, 7, tc.target)
			status, commits, writes := 200, 0, tc.failWrite
			var failure *groupMembershipFailure
			if errors.As(err, &failure) {
				status = failure.status
			} else if err != nil {
				status = 500
			}
			if tc.want == 200 {
				commits, writes = 1, 4
			}
			if status != tc.want || f.state.commits != commits || f.state.rollbacks != 1-commits || len(f.writes) != writes {
				t.Fatalf("status=%d commits=%d rollbacks=%d writes=%v err=%v", status, f.state.commits, f.state.rollbacks, f.writes, err)
			}
			statements := []string{demoteGroupOwnerSQL, promoteGroupOwnerSQL, transferGroupOwnershipSQL, groupAdmissionAuditSQL}
			if writes != 0 && !reflect.DeepEqual(f.writes, statements[:writes]) {
				t.Fatalf("write order: %v", f.writes)
			}
		})
	}
}
