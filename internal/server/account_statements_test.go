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
	"testing"
)

type statementFixture struct {
	*memorySessions
	status, pending string
	created         int
}

func (*statementFixture) ListAccountStatements(_ context.Context, user int64, status, kind string, page SessionPage) ([]accountStatement, int64, error) {
	if user != 42 || status != "unread" || kind != "warning" || page.Start != 3 || page.End != 4 {
		return nil, 0, errSessionStore
	}
	return nil, 2, nil
}

func (s *statementFixture) SetAccountStatementStatus(_ context.Context, user, id int64, status string) (statementStatus, error) {
	if user != 42 || id != 9 {
		return statementStatus{}, errStatementMissing
	}
	s.status = status
	return statementStatus{ID: id, Status: status, UpdatedAt: "2026-11-16T08:00:00.000Z"}, nil
}

func (s *statementFixture) SubmitAccountAppeal(_ context.Context, user, id int64, message string) (statementAppeal, error) {
	if id == 10 {
		return statementAppeal{}, errSessionStore
	}
	if user != 42 || id != 9 {
		return statementAppeal{}, errStatementMissing
	}
	if s.pending == "" {
		s.pending, s.status = message, "appealed"
		s.created++
	} else if s.pending != message {
		return statementAppeal{}, errAppealPending
	}
	return statementAppeal{ID: id, Status: s.status, AppealID: 12, AppealStatus: "pending"}, nil
}

func TestAccountStatementsSharedRoutes(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/account-statements.json")
	if err != nil {
		t.Fatal(err)
	}
	var scenarios struct {
		Cases []struct {
			ID, Method, Path string
			Status           int
			Body             json.RawMessage
			Data, Meta       map[string]any
		}
	}
	if err := json.Unmarshal(raw, &scenarios); err != nil {
		t.Fatal(err)
	}
	codec, tokens := fixture(t)
	repository := &statementFixture{memorySessions: store(), status: "unread"}
	handler := NewHandler(codec, repository, CorsPolicy{})
	for _, tc := range scenarios.Cases {
		t.Run(tc.ID, func(t *testing.T) {
			request := httptest.NewRequest(tc.Method, tc.Path, bytes.NewReader(tc.Body))
			if tc.Status != 401 {
				request.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			}
			request.Header.Set("Content-Type", "application/json")
			res := httptest.NewRecorder()
			handler.ServeHTTP(res, request)
			if res.Code != tc.Status || res.Header().Get("Cache-Control") != "private, no-store" {
				t.Fatal(res.Code, res.Body.String())
			}
			var payload struct {
				Data any
				Meta map[string]any
			}
			if err := json.Unmarshal(res.Body.Bytes(), &payload); err != nil {
				t.Fatal(err)
			}
			if tc.Data != nil && !reflect.DeepEqual(payload.Data, tc.Data) {
				t.Fatal(payload.Data)
			}
			if tc.Meta != nil && (!reflect.DeepEqual(payload.Meta, tc.Meta) || !reflect.DeepEqual(payload.Data, []any{})) {
				t.Fatal(payload)
			}
		})
	}
	if repository.created != 1 || repository.pending != "Check rule application" {
		t.Fatal("duplicate or modified appeal")
	}
}

func TestAccountStatementAppealRollsBackBothWrites(t *testing.T) {
	for _, fail := range []int{0, 1, 2} {
		state := &resetTransactionState{claim: 1, user: 1, failAt: fail}
		state.queryRows = map[string]driver.Value{statementContract.SQL["lock"]: "read", statementContract.SQL["next"]: int64(12)}
		db := sql.OpenDB(resetTransactionConnector{state})
		receipt, err := (OracleSessions{db}).SubmitAccountAppeal(context.Background(), 42, 9, "Check rule application")
		_ = db.Close()
		if fail == 0 {
			if err != nil || receipt.AppealID != 12 || state.commits != 1 || len(state.queries) != 2 {
				t.Fatal(err, receipt, state.queries)
			}
		} else if err == nil || state.commits != 0 || state.rollbacks != 1 || len(state.queries) != fail {
			t.Fatal("partial appeal did not roll back", err, state.queries)
		}
		for _, bind := range state.binds {
			scoped := map[string]any{}
			for _, arg := range bind {
				scoped[arg.Name] = arg.Value
			}
			if scoped["user_id"] != int64(42) || scoped["statement_id"] != int64(9) {
				t.Fatal(scoped)
			}
		}
	}
}
