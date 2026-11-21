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
	"reflect"
	"testing"
)

type reportTransactionConnector struct {
	resetTransactionConnector
	status, next string
	resolved     int64
	failRead     bool
}

func (c reportTransactionConnector) Connect(context.Context) (driver.Conn, error) {
	return &reportTransactionConn{
		resetTransactionConn: &resetTransactionConn{testConn: &testConn{state: &c.state.driverState}, state: c.state},
		fixture:              c,
	}, nil
}

type reportTransactionConn struct {
	*resetTransactionConn
	fixture reportTransactionConnector
}

type submitTransactionConnector struct {
	resetTransactionConnector
	openReason string
}

func (c submitTransactionConnector) Connect(context.Context) (driver.Conn, error) {
	return &submitTransactionConn{
		resetTransactionConn: &resetTransactionConn{testConn: &testConn{state: &c.state.driverState}, state: c.state},
		openReason:           c.openReason,
	}, nil
}

type submitTransactionConn struct {
	*resetTransactionConn
	openReason string
}

func (c *submitTransactionConn) QueryContext(_ context.Context, query string, _ []driver.NamedValue) (driver.Rows, error) {
	var row appealRows
	switch query {
	case moderationReportsContract.Create.Targets["post"]:
		row = appealRows{int64(30)}
	case moderationReportsContract.SQL["findOpen"]:
		if c.openReason != "" {
			row = appealRows{int64(15), c.openReason, "Detail", nil, "normal"}
		}
	case moderationReportsContract.SQL["next"]:
		row = appealRows{int64(15)}
	case moderationReportsContract.SQL["read"]:
		row = appealRows{int64(15), "post", int64(30), nil, "spam", "Detail", nil, "pending",
			"normal", nil, "2026-11-16T00:00:00.000Z", "2026-11-16T00:00:00.000Z", nil, int64(0)}
	default:
		return nil, errors.New("unexpected query")
	}
	return &row, nil
}

func TestModerationReportCreateTransaction(t *testing.T) {
	for _, tc := range []struct {
		name, openReason  string
		failWrite, writes int
		committed         bool
	}{
		{"new report", "", 0, 2, true},
		{"merge fails", "", 2, 2, false},
		{"identical retry", "spam", 0, 0, true},
		{"different open report", "hate", 0, 0, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			state := &resetTransactionState{claim: 1, user: 1, failAt: tc.failWrite}
			db := sql.OpenDB(submitTransactionConnector{resetTransactionConnector{state}, tc.openReason})
			defer db.Close()
			input := reportInput{TargetID: 30, TargetType: "post", Reason: "spam", Description: "Detail", Priority: "normal"}
			report, err := (OracleSessions{db}).CreateReport(context.Background(), 42, input, StorageURLPolicy{})
			if tc.committed {
				if err != nil || report.ID != 15 || state.commits != 1 || state.rollbacks != 0 {
					t.Fatal(report, err, state.commits, state.rollbacks)
				}
			} else if err == nil || state.commits != 0 || state.rollbacks != 1 {
				t.Fatal(err, state.commits, state.rollbacks)
			}
			if len(state.queries) != tc.writes {
				t.Fatal(state.queries)
			}
			if tc.writes > 0 && (state.queries[0] != moderationReportsContract.SQL["insert"] ||
				state.queries[1] != moderationReportsContract.SQL["mergeCase"]) {
				t.Fatal(state.queries)
			}
		})
	}
}

func (c *reportTransactionConn) QueryContext(_ context.Context, query string, _ []driver.NamedValue) (driver.Rows, error) {
	var row appealRows
	switch query {
	case moderationReportsContract.SQL["lock"]:
		row = appealRows{c.fixture.status, int64(42), c.fixture.resolved}
	case moderationReportsContract.SQL["read"]:
		if c.fixture.failRead {
			return nil, errors.New("isolated report readback failure")
		}
		row = appealRows{int64(12), "post", int64(30), nil, "spam", nil, nil, c.fixture.next,
			"normal", nil, "2026-11-16T00:00:00.000Z", "2026-11-16T01:00:00.000Z", nil, int64(0)}
	default:
		return nil, errors.New("unexpected query")
	}
	return &row, nil
}

func TestModerationReportTransaction(t *testing.T) {
	for _, tc := range []struct {
		name, current, next string
		resolved            int64
		failRead            bool
		writes              int
	}{
		{"resolve", "pending", "resolved", 0, false, 1},
		{"repeat", "resolved", "resolved", 1, false, 0},
		{"reopen", "resolved", "pending", 1, false, 1},
		{"readback fails", "pending", "resolved", 0, true, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			state := &resetTransactionState{claim: 1}
			db := sql.OpenDB(reportTransactionConnector{resetTransactionConnector{state}, tc.current, tc.next, tc.resolved, tc.failRead})
			defer db.Close()
			report, err := (OracleSessions{db}).UpdateModerationReport(context.Background(), 42, 12, tc.next, StorageURLPolicy{})
			if tc.failRead {
				if err == nil || state.commits != 0 || state.rollbacks != 1 {
					t.Fatal(err, state.commits, state.rollbacks)
				}
			} else if err != nil || report.Status != tc.next || state.commits != 1 || state.rollbacks != 0 {
				t.Fatal(report, err, state.commits, state.rollbacks)
			}
			if len(state.queries) != tc.writes || (tc.writes > 0 && state.queries[0] != moderationReportsContract.SQL["update"]) {
				t.Fatal(state.queries)
			}
		})
	}
}

type moderationReportFixture struct {
	*memorySessions
	denied  bool
	created *reportInput
}

func (s *moderationReportFixture) CreateReport(_ context.Context, actor int64, input reportInput, _ StorageURLPolicy) (moderationReport, error) {
	if actor != 42 || input.TargetType != "post" {
		return moderationReport{}, errSessionStore
	}
	switch input.TargetID {
	case 99:
		return moderationReport{}, sql.ErrNoRows
	case 13:
		return moderationReport{}, errSessionStore
	case 30:
		if s.created != nil && *s.created != input {
			return moderationReport{}, errOpenReport
		}
		s.created = &input
		return moderationReport{ID: 15, TargetType: input.TargetType, TargetID: input.TargetID, Reason: input.Reason, Description: input.Description, EvidenceURL: &input.EvidenceURL}, nil
	default:
		return moderationReport{}, errSessionStore
	}
}

func (s *moderationReportFixture) ModerationAllowed(_ context.Context, actor int64, policy moderationPolicy) (bool, error) {
	return actor == 42 && policy.Accounts["reviewer"] && !s.denied, nil
}

func (*moderationReportFixture) ListModerationReports(_ context.Context, actor int64, filters reportFilters, page SessionPage, _ StorageURLPolicy) ([]moderationReport, int64, error) {
	if actor != 42 || filters != (reportFilters{Status: "pending", Reason: "spam", TargetType: "group_post"}) || page.Start != 3 || page.End != 4 {
		return nil, 0, errSessionStore
	}
	return []moderationReport{}, 2, nil
}

func (*moderationReportFixture) UpdateModerationReport(_ context.Context, actor, id int64, status string, _ StorageURLPolicy) (moderationReport, error) {
	if id == 13 || actor != 42 {
		return moderationReport{}, errSessionStore
	}
	if id != 12 {
		return moderationReport{}, sql.ErrNoRows
	}
	return moderationReport{ID: id, Status: status}, nil
}

func TestNativeModerationReportRoutes(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/moderation-reports.json")
	if err != nil {
		t.Fatal(err)
	}
	var scenarios struct {
		Cases []struct {
			ID, Method, Path, ExpectStatus string
			Status, ReportID               int
			Denied                         bool
			Body                           json.RawMessage
			Meta                           map[string]any
		}
	}
	if err := json.Unmarshal(raw, &scenarios); err != nil {
		t.Fatal(err)
	}
	codec, tokens := fixture(t)
	store := &moderationReportFixture{memorySessions: store()}
	handler := NewHandlerWithConfig(codec, store, CorsPolicy{}, RefreshConfig{ModerationAdminAccounts: " Reviewer "})
	for _, tt := range scenarios.Cases {
		t.Run(tt.ID, func(t *testing.T) {
			store.denied = tt.Denied
			req := httptest.NewRequest(tt.Method, tt.Path, bytes.NewReader(tt.Body))
			req.Header.Set("Content-Type", "application/json")
			if tt.Status != 401 {
				req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			}
			res := httptest.NewRecorder()
			handler.ServeHTTP(res, req)
			if res.Code != tt.Status || res.Header().Get("Cache-Control") != "private, no-store" {
				t.Fatal(res.Code, res.Body.String())
			}
			var payload struct {
				Data json.RawMessage
				Meta map[string]any
			}
			if err := json.Unmarshal(res.Body.Bytes(), &payload); err != nil {
				t.Fatal(err)
			}
			if tt.Meta != nil && (string(payload.Data) != "[]" || !reflect.DeepEqual(tt.Meta, payload.Meta)) {
				t.Fatal(res.Body.String())
			}
			if tt.ExpectStatus != "" {
				var report moderationReport
				if err := json.Unmarshal(payload.Data, &report); err != nil || report.ID != 12 || report.Status != tt.ExpectStatus {
					t.Fatal(res.Body.String())
				}
			}
			if tt.ReportID != 0 {
				var report moderationReport
				if err := json.Unmarshal(payload.Data, &report); err != nil || report.ID != int64(tt.ReportID) || report.Description != "Detail" || report.EvidenceURL == nil || *report.EvidenceURL != "/tweet/30" {
					t.Fatal(res.Body.String())
				}
			}
		})
	}
}
