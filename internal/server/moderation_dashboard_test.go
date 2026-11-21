package server

import (
	"bytes"
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"net/http/httptest"
	"os"
	"reflect"
	"slices"
	"testing"
)

type dashboardFixture struct {
	*memorySessions
	denied   bool
	settings []dashboardSetting
}

func (s *dashboardFixture) ModerationAllowed(_ context.Context, actor int64, policy moderationPolicy) (bool, error) {
	return actor == 42 && policy.Accounts["reviewer"] && !s.denied, nil
}

func (*dashboardFixture) ModerationStats(context.Context) (dashboardStats, error) {
	return dashboardStats{2, 3, 1, 2, 6, 15, 4, 67}, nil
}

func (s *dashboardFixture) ModerationSettings(context.Context) ([]dashboardSetting, error) {
	return s.settings, nil
}

func (s *dashboardFixture) UpdateModerationSettings(_ context.Context, actor int64, batch []dashboardChange) ([]dashboardSetting, error) {
	if actor != 42 {
		return nil, errSessionStore
	}
	if len(batch) == 0 {
		return s.settings, nil
	}
	if len(batch) != 2 || batch[0].key != "default_mute_hours" || batch[1].key != "require_note_on_reject" {
		return nil, errSessionStore
	}
	if batch[0].value == "77" {
		return nil, errSessionStore
	}
	s.settings[0].Value = batch[0].value
	s.settings[1].Value = batch[1].value
	return s.settings, nil
}

func TestNativeModerationDashboard(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/moderation-dashboard.json")
	if err != nil {
		t.Fatal(err)
	}
	var spec struct {
		Cases []struct {
			ID, Method, Path string
			Body             json.RawMessage
			Status           int
			Denied           bool
			Stats            *dashboardStats
			Values           map[string]string
		}
	}
	if err := json.Unmarshal(raw, &spec); err != nil {
		t.Fatal(err)
	}
	codec, tokens := fixture(t)
	store := &dashboardFixture{memorySessions: store(), settings: []dashboardSetting{
		{Key: "default_mute_hours", Value: "24", Type: "number"},
		{Key: "require_note_on_reject", Value: "true", Type: "boolean"},
	}}
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
			var payload struct{ Data json.RawMessage }
			if err := json.Unmarshal(res.Body.Bytes(), &payload); err != nil {
				t.Fatal(err)
			}
			if vector.Stats != nil {
				var stats dashboardStats
				if err := json.Unmarshal(payload.Data, &stats); err != nil || stats != *vector.Stats {
					t.Fatal(res.Body.String())
				}
			}
			if vector.Values != nil {
				var items []dashboardSetting
				if err := json.Unmarshal(payload.Data, &items); err != nil {
					t.Fatal(err)
				}
				values := map[string]string{}
				for _, item := range items {
					values[item.Key] = item.Value
				}
				if !reflect.DeepEqual(values, vector.Values) {
					t.Fatal(res.Body.String())
				}
			}
		})
	}
}

type dashboardTransactionConnector struct{ resetTransactionConnector }
type dashboardTransactionConn struct{ *resetTransactionConn }

func (c dashboardTransactionConnector) Connect(context.Context) (driver.Conn, error) {
	return &dashboardTransactionConn{&resetTransactionConn{testConn: &testConn{state: &c.state.driverState}, state: c.state}}, nil
}

func (c *dashboardTransactionConn) QueryContext(_ context.Context, query string, _ []driver.NamedValue) (driver.Rows, error) {
	if query != moderationDashboardContract.SQL["list"] || len(c.state.queries) != 2 {
		return nil, errSessionStore
	}
	row := appealRows{"default_mute_hours", "36", "number", nil, nil, "2026-11-16T00:00:00.000Z"}
	return &row, nil
}

func TestModerationDashboardUpdateTransaction(t *testing.T) {
	for _, fail := range []int{0, 2} {
		state := &resetTransactionState{claim: 1, user: 1, failAt: fail}
		db := sql.OpenDB(dashboardTransactionConnector{resetTransactionConnector{state}})
		settings, err := (OracleSessions{db}).UpdateModerationSettings(context.Background(), 42, []dashboardChange{
			{"default_mute_hours", "36", "number"}, {"require_note_on_reject", "false", "boolean"},
		})
		db.Close()
		if fail == 0 {
			if err != nil || len(settings) != 1 || settings[0].Value != "36" || state.commits != 1 || state.rollbacks != 0 {
				t.Fatal(settings, err, state.commits, state.rollbacks)
			}
		} else if err == nil || state.commits != 0 || state.rollbacks != 1 {
			t.Fatal(err, state.commits, state.rollbacks)
		}
		if !slices.Equal(state.queries, []string{moderationDashboardContract.SQL["update"], moderationDashboardContract.SQL["update"]}) {
			t.Fatal(state.queries)
		}
	}
}
