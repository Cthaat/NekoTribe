package server

import (
	"bytes"
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"io"
	"net/http/httptest"
	"os"
	"reflect"
	"slices"
	"testing"
)

type moderationAppealFixture struct {
	*memorySessions
	denied        bool
	status, reply string
	decisions     int
}

type moderationAppealsConnector struct {
	state *resetTransactionState
	final bool
}

func (c moderationAppealsConnector) Driver() driver.Driver { return testDriver{} }
func (c moderationAppealsConnector) Connect(context.Context) (driver.Conn, error) {
	return &moderationAppealsConn{
		resetTransactionConn: &resetTransactionConn{testConn: &testConn{state: &c.state.driverState}, state: c.state},
		final:                c.final,
	}, nil
}

type moderationAppealsConn struct {
	*resetTransactionConn
	final bool
}

type appealRows []driver.Value

func (r *appealRows) Columns() []string { return make([]string, len(*r)) }
func (r *appealRows) Close() error      { return nil }
func (r *appealRows) Next(dest []driver.Value) error {
	if *r == nil {
		return io.EOF
	}
	copy(dest, *r)
	*r = nil
	return nil
}

func (c *moderationAppealsConn) QueryContext(_ context.Context, query string, _ []driver.NamedValue) (driver.Rows, error) {
	var row appealRows
	switch query {
	case moderationAppealsContract.SQL["lock"]:
		status, reply := "pending", ""
		if c.final {
			status, reply = "approved", "Reviewed"
		}
		row = appealRows{int64(7), status, reply}
	case moderationAppealsContract.SQL["read"]:
		row = appealRows{int64(7), "member", nil, "Member", nil, nil, nil, int64(0), int64(0), int64(0), int64(0), int64(0), "offline", nil, "none",
			int64(12), int64(9), "Please review", "approved", "Reviewed", "2026-11-16T00:00:00.000Z", "2026-11-16T01:00:00.000Z", int64(0)}
	default:
		return nil, errors.New("unexpected query")
	}
	return &row, nil
}

func TestModerationAppealsTransactionKeepsDecisionAndAuditTogether(t *testing.T) {
	for _, tc := range []struct {
		name    string
		final   bool
		status  string
		failAt  int
		success bool
		writes  int
	}{
		{"new decision", false, "approved", 0, true, 2},
		{"audit fails", false, "approved", 2, false, 2},
		{"identical retry", true, "approved", 0, true, 0},
		{"stale decision", true, "rejected", 0, false, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			state := &resetTransactionState{claim: 1, user: 1, failAt: tc.failAt}
			db := sql.OpenDB(moderationAppealsConnector{state: state, final: tc.final})
			defer db.Close()
			got, err := (OracleSessions{db}).DecideModerationAppeal(context.Background(), 42, 12, tc.status, "Reviewed", StorageURLPolicy{})
			if tc.success {
				if err != nil || got.Status != tc.status || state.commits != 1 || state.rollbacks != 0 {
					t.Fatal(got, err, state.commits, state.rollbacks)
				}
			} else if err == nil || state.commits != 0 || state.rollbacks != 1 {
				t.Fatal(err, state.commits, state.rollbacks)
			}
			if len(state.queries) != tc.writes {
				t.Fatal(state.queries)
			}
			if tc.writes == 2 {
				if !slices.Equal(state.queries, []string{moderationAppealsContract.SQL["update"], moderationAppealsContract.SQL["audit"]}) {
					t.Fatal(state.queries)
				}
				binds := map[string]any{}
				for _, arg := range state.binds[1] {
					binds[arg.Name] = arg.Value
				}
				if binds["viewer_id"] != int64(42) || binds["target_id"] != int64(7) || binds["reason"] != "appeal:12" {
					t.Fatal(binds)
				}
			}
		})
	}
}

func (s *moderationAppealFixture) ModerationAllowed(_ context.Context, actor int64, policy moderationPolicy) (bool, error) {
	if actor != 42 || policy.AllowAll || !policy.Accounts["reviewer"] {
		return false, errSessionStore
	}
	return !s.denied, nil
}

func (*moderationAppealFixture) ListModerationAppeals(_ context.Context, actor int64, status string, page SessionPage, _ StorageURLPolicy) ([]moderationAppeal, int64, error) {
	if actor != 42 || status != "pending" || page.Start != 3 || page.End != 4 {
		return nil, 0, errSessionStore
	}
	return nil, 2, nil
}

func (s *moderationAppealFixture) DecideModerationAppeal(_ context.Context, actor, id int64, status, reply string, _ StorageURLPolicy) (moderationAppeal, error) {
	if actor != 42 || id == 13 {
		return moderationAppeal{}, errSessionStore
	}
	if id != 12 {
		return moderationAppeal{}, errModerationAppealMissing
	}
	if s.status == "" {
		s.status, s.reply = status, reply
		s.decisions++
	} else if s.status != status || s.reply != reply {
		return moderationAppeal{}, errModerationAppealHandled
	}
	return moderationAppeal{ID: id, StatementID: 9, User: PublicUser{UserID: 7}, Status: s.status, AdminResponse: s.reply}, nil
}

func TestModerationAppealsSharedRoutes(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/moderation-appeals.json")
	if err != nil {
		t.Fatal(err)
	}
	var spec struct {
		Cases []struct {
			ID, Method, Path, Decision, Reply string
			Status                            int
			Denied                            bool
			Body                              json.RawMessage
			Meta                              map[string]any
		}
	}
	if err := json.Unmarshal(raw, &spec); err != nil {
		t.Fatal(err)
	}
	codec, tokens := fixture(t)
	store := &moderationAppealFixture{memorySessions: store()}
	handler := NewHandlerWithConfig(codec, store, CorsPolicy{}, RefreshConfig{ModerationAdminAccounts: " Reviewer "})
	for _, vector := range spec.Cases {
		t.Run(vector.ID, func(t *testing.T) {
			store.denied = vector.Denied
			req := httptest.NewRequest(vector.Method, vector.Path, bytes.NewReader(vector.Body))
			req.Header.Set("Content-Type", "application/json")
			if vector.Status != 401 {
				req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			}
			res := httptest.NewRecorder()
			handler.ServeHTTP(res, req)
			if res.Code != vector.Status || res.Header().Get("Cache-Control") != "private, no-store" {
				t.Fatal(res.Code, res.Body.String())
			}
			var payload struct {
				Data json.RawMessage
				Meta map[string]any
			}
			if err := json.Unmarshal(res.Body.Bytes(), &payload); err != nil {
				t.Fatal(err)
			}
			if vector.Meta != nil && (!reflect.DeepEqual(payload.Meta, vector.Meta) || string(payload.Data) != "[]") {
				t.Fatal(res.Body.String())
			}
			if vector.Decision != "" {
				var result moderationAppeal
				if err := json.Unmarshal(payload.Data, &result); err != nil {
					t.Fatal(err)
				}
				if result.ID != 12 || result.User.UserID != 7 || result.Status != vector.Decision || result.AdminResponse != vector.Reply {
					t.Fatal(result)
				}
			}
		})
	}
	if store.decisions != 1 {
		t.Fatal("identical retry repeated the decision")
	}
}
