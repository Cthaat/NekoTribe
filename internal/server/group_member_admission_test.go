package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"testing"
)

type admissionFixture struct {
	state                    driverState
	targetRole, targetStatus string
	actorRole                string
	missingExpiry            bool
	auditFailure             bool
	writes                   []string
}

type admissionConn struct {
	*testConn
	fixture *admissionFixture
}

func (*admissionFixture) Driver() driver.Driver { return testDriver{} }

func (f *admissionFixture) Connect(context.Context) (driver.Conn, error) {
	return &admissionConn{&testConn{&f.state}, f}, nil
}

func (c *admissionConn) QueryContext(_ context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	switch query {
	case membershipGroupSQL:
		return &alertRows{values: []driver.Value{int64(90), "public", int64(1), int64(1), int64(0)}}, nil
	case membershipReadSQL:
		if args[1].Value == int64(42) {
			role := c.fixture.actorRole
			if role == "" {
				role = "moderator"
			}
			return &alertRows{values: []driver.Value{role, "active"}}, nil
		}
		return &alertRows{values: []driver.Value{c.fixture.targetRole, c.fixture.targetStatus}}, nil
	case groupApprovalTargetSQL:
		return &alertRows{values: []driver.Value{int64(9), c.fixture.targetRole, c.fixture.targetStatus}}, nil
	case groupMuteUntilSQL:
		return &alertRows{values: []driver.Value{"2026-11-17T12:00:00.000Z"}, done: c.fixture.missingExpiry}, nil
	default:
		return nil, errors.New("unexpected query")
	}
}

func TestGroupModerationRespectsHierarchyAndAudit(t *testing.T) {
	for _, tc := range []struct {
		name, actor, role, status   string
		change                      groupMemberChange
		missingExpiry               bool
		wantStatus, writes, commits int
	}{
		{"admin grants moderator", "admin", "member", "active", groupMemberChange{action: groupRole, role: "moderator"}, false, 200, 2, 1},
		{"admin cannot grant own rank", "admin", "member", "active", groupMemberChange{action: groupRole, role: "admin"}, false, 422, 0, 0},
		{"unchanged role", "admin", "member", "active", groupMemberChange{action: groupRole, role: "member"}, false, 200, 0, 0},
		{"mute returns database expiry", "moderator", "member", "active", groupMemberChange{action: groupMute, hours: 24}, false, 200, 2, 1},
		{"mute rolls back on missing expiry", "moderator", "member", "muted", groupMemberChange{action: groupMute, hours: 24}, true, 500, 1, 0},
		{"pending cannot be muted", "moderator", "member", "pending", groupMemberChange{action: groupMute, hours: 24}, false, 422, 0, 0},
		{"unmute transitions muted to active", "moderator", "member", "muted", groupMemberChange{action: groupUnmute}, false, 200, 2, 1},
		{"active unmute is idempotent", "moderator", "member", "active", groupMemberChange{action: groupUnmute}, false, 200, 0, 0},
		{"unmute preserves ban", "moderator", "member", "banned", groupMemberChange{action: groupUnmute}, false, 422, 0, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := &admissionFixture{actorRole: tc.actor, targetRole: tc.role, targetStatus: tc.status, missingExpiry: tc.missingExpiry}
			db := sql.OpenDB(f)
			defer db.Close()
			expiry, err := (OracleSessions{DB: db}).ManageGroupMember(context.Background(), 42, 7, 9, tc.change)
			status := 200
			var failure *groupMembershipFailure
			if errors.As(err, &failure) {
				status = failure.status
			} else if err != nil {
				status = 500
			}
			if status != tc.wantStatus || len(f.writes) != tc.writes || f.state.commits != tc.commits || f.state.rollbacks != 1-tc.commits {
				t.Fatalf("status=%d writes=%v commits=%d rollbacks=%d err=%v", status, f.writes, f.state.commits, f.state.rollbacks, err)
			}
			if err == nil && tc.change.action == groupMute && expiry != "2026-11-17T12:00:00.000Z" {
				t.Fatalf("expiry=%q", expiry)
			}
		})
	}
}

func (c *admissionConn) ExecContext(_ context.Context, query string, args []driver.NamedValue) (driver.Result, error) {
	c.fixture.writes = append(c.fixture.writes, query)
	if query == groupAdmissionAuditSQL {
		if args[2].Value != int64(9) || c.fixture.auditFailure {
			return nil, errors.New("audit failed")
		}
	}
	return driver.RowsAffected(1), nil
}

func TestGroupAdmissionCommitsAuditAndPreservesProtectedMemberships(t *testing.T) {
	for _, tc := range []struct {
		action       groupAdmissionAction
		role, status string
		failAudit    bool
		wantStatus   int
		write        string
	}{
		{groupApprove, "member", "pending", false, 200, groupApproveSQL},
		{groupReject, "member", "pending", false, 200, groupRejectSQL},
		{groupReject, "member", "active", false, 422, ""},
		{groupRemove, "member", "muted", false, 200, membershipDeleteSQL},
		{groupRemove, "member", "banned", false, 422, ""},
		{groupRemove, "moderator", "active", false, 422, ""},
		{groupRemove, "owner", "active", false, 422, ""},
		{groupApprove, "member", "pending", true, 500, groupApproveSQL},
	} {
		t.Run(string(tc.action)+" "+tc.role+" "+tc.status, func(t *testing.T) {
			f := &admissionFixture{targetRole: tc.role, targetStatus: tc.status, auditFailure: tc.failAudit}
			db := sql.OpenDB(f)
			defer db.Close()
			target := int64(9)
			if tc.action != groupRemove {
				target = 12
			}
			_, err := (OracleSessions{DB: db}).ManageGroupMember(context.Background(), 42, 7, target, groupMemberChange{action: tc.action})
			status := 200
			var failure *groupMembershipFailure
			if errors.As(err, &failure) {
				status = failure.status
			} else if err != nil {
				status = 500
			}
			commits := 0
			if tc.wantStatus == 200 {
				commits = 1
			}
			if status != tc.wantStatus || f.state.commits != commits || f.state.rollbacks != 1-commits {
				t.Fatalf("status=%d commits=%d rollbacks=%d error=%v", status, f.state.commits, f.state.rollbacks, err)
			}
			if tc.write == "" {
				if len(f.writes) != 0 {
					t.Fatal("protected membership was written")
				}
			} else if len(f.writes) != 2 || f.writes[0] != tc.write || f.writes[1] != groupAdmissionAuditSQL {
				t.Fatalf("writes=%v", f.writes)
			}
		})
	}
}
