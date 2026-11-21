package server

import (
	"bytes"
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"os"
	"slices"
	"testing"
)

type userActionVector struct {
	ID, Method, Path  string
	Body              json.RawMessage
	Status            int
	Denied, AuditFail bool
	Hours             *int64
	Item              *moderationQueueUser
}
type userActionFixture struct {
	*dashboardFixture
	vector userActionVector
}

func (s *userActionFixture) ModerateUser(_ context.Context, actor int64, input userActionInput, _ StorageURLPolicy) (moderationQueueUser, error) {
	v := s.vector
	if actor != 42 {
		return moderationQueueUser{}, errSessionStore
	}
	switch input.ID {
	case 99:
		return moderationQueueUser{}, errModerationUserMissing
	case 9, 10:
		return moderationQueueUser{}, errModerationUserState
	}
	if v.AuditFail {
		return moderationQueueUser{}, errSessionStore
	}
	if v.Item == nil || v.Item.ID != input.ID {
		return moderationQueueUser{}, errSessionStore
	}
	if v.ID == "explicit-mute" && (input.Hours == nil || *input.Hours != 3 || input.Note != "reviewed") {
		return moderationQueueUser{}, errSessionStore
	}
	if v.ID == "indefinite-ban" && (input.Hours == nil || *input.Hours != 0) {
		return moderationQueueUser{}, errSessionStore
	}
	if (v.ID == "default-mute" || v.ID == "default-ban") && input.Hours != nil {
		return moderationQueueUser{}, errSessionStore
	}
	return *v.Item, nil
}

func TestNativeModerationUserActions(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/moderation-user-actions.json")
	if err != nil {
		t.Fatal(err)
	}
	var spec struct{ Cases []userActionVector }
	if err := json.Unmarshal(raw, &spec); err != nil {
		t.Fatal(err)
	}
	codec, tokens := fixture(t)
	repo := &userActionFixture{dashboardFixture: &dashboardFixture{memorySessions: store()}}
	handler := NewHandlerWithConfig(codec, repo, CorsPolicy{}, RefreshConfig{ModerationAdminAccounts: " Reviewer "})
	for _, v := range spec.Cases {
		t.Run(v.ID, func(t *testing.T) {
			repo.vector = v
			repo.denied = v.Denied
			req := httptest.NewRequest(v.Method, v.Path, bytes.NewReader(v.Body))
			req.Header.Set("Content-Type", "application/json")
			if v.Status != 401 {
				req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			}
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, req)
			if response.Code != v.Status || response.Header().Get("Cache-Control") != "private, no-store" {
				t.Fatal(response.Code, response.Body.String())
			}
			if v.Item != nil {
				var payload struct{ Data moderationQueueUser }
				if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil || payload.Data.ID != v.Item.ID || payload.Data.Status != v.Item.Status || payload.Data.Active != v.Item.Active {
					t.Fatal(response.Body.String())
				}
			}
		})
	}
}

type userActionTxConnector struct {
	resetTransactionConnector
	fail     bool
	reported *[]driver.NamedValue
	verb     string
}
type userActionTxConn struct {
	*resetTransactionConn
	config userActionTxConnector
	locked bool
}

func (c userActionTxConnector) Connect(context.Context) (driver.Conn, error) {
	return &userActionTxConn{resetTransactionConn: &resetTransactionConn{testConn: &testConn{state: &c.state.driverState}, state: c.state}, config: c}, nil
}
func (c *userActionTxConn) QueryContext(_ context.Context, q string, binds []driver.NamedValue) (driver.Rows, error) {
	var row appealRows
	switch q {
	case moderationUserActions.SQL["lock"]:
		c.locked = true
		row = appealRows{int64(7), "active", int64(1)}
	case moderationUserActions.SQL["case"]:
		row = appealRows{int64(15)}
	case moderationUserActions.SQL["defaultMute"]:
		row = appealRows{" 36 "}
	case moderationUsersContract.SQL:
		if !c.locked || c.state.commits != 0 {
			return nil, errors.New("readback outside of transaction")
		}
		var id any
		for _, bind := range binds {
			if bind.Name == "user_id" {
				id = bind.Value
			}
		}
		if id != int64(7) {
			return nil, errors.New("wrong readback id")
		}
		status, active := "active", int64(1)
		if c.config.verb == "ban" {
			status, active = "suspended", 0
		}
		row = appealRows{int64(7), "member", "Member", nil, "fixture@example.test", status, active, int64(0),
			int64(0), int64(0), int64(0), int64(0), nil, nil, nil, nil, int64(1)}
	default:
		return nil, errors.New("unexpected user action query")
	}
	return &row, nil
}
func (c *userActionTxConn) ExecContext(_ context.Context, q string, binds []driver.NamedValue) (driver.Result, error) {
	if !c.locked {
		return nil, errors.New("write before locking user")
	}
	c.state.queries = append(c.state.queries, q)
	if q == moderationUserActions.SQL["audit"] {
		*c.config.reported = binds
		if c.config.fail {
			return nil, errors.New("isolated audit failure")
		}
	}
	return driver.RowsAffected(1), nil
}

func TestUserModerationTransactions(t *testing.T) {
	for _, v := range []struct {
		action string
		fail   bool
		hours  int64
		writes []string
	}{
		{"ban", false, 24, []string{"updateUser", "revokeSessions", "revokeRestriction", "addRestriction", "audit"}},
		{"ban", true, 24, []string{"updateUser", "revokeSessions", "revokeRestriction", "addRestriction", "audit"}},
		{"mute", false, 36, []string{"revokeRestriction", "addRestriction", "audit"}},
	} {
		t.Run(v.action+map[bool]string{false: "-commit", true: "-rollback"}[v.fail], func(t *testing.T) {
			state := &resetTransactionState{}
			var audit []driver.NamedValue
			db := sql.OpenDB(userActionTxConnector{resetTransactionConnector{state}, v.fail, &audit, v.action})
			defer db.Close()
			result, err := (OracleSessions{DB: db}).ModerateUser(context.Background(), 42, userActionInput{ID: 7, Action: v.action}, StorageURLPolicy{})
			if v.fail {
				if err == nil || state.commits != 0 || state.rollbacks != 1 {
					t.Fatal(result, err, state.commits, state.rollbacks)
				}
			} else if err != nil || result.ID != 7 || state.commits != 1 || state.rollbacks != 0 {
				t.Fatal(result, err, state.commits, state.rollbacks)
			}
			expected := make([]string, 0, len(v.writes))
			for _, name := range v.writes {
				expected = append(expected, moderationUserActions.SQL[name])
			}
			if !slices.Equal(state.queries, expected) {
				t.Fatal(state.queries)
			}
			var duration any
			for _, arg := range audit {
				if arg.Name == "hours" {
					duration = arg.Value
				}
			}
			if duration != v.hours {
				t.Fatal(audit)
			}
		})
	}
}
