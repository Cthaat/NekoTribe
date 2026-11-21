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
	"slices"
	"testing"
)

type postActionVector struct {
	ID, Path, Method, Setting string
	Status, Processed         int
	Denied                    bool
	Assigned, AuditFail       int64
	Body                      json.RawMessage
	Item                      *contentQueueItem
}

type postActionFixture struct {
	*dashboardFixture
	vector postActionVector
}

func (s *postActionFixture) ModeratePosts(_ context.Context, actor int64, input postActionInput, _ StorageURLPolicy) (postActionResult, error) {
	v := s.vector
	if actor != 42 {
		return postActionResult{}, errSessionStore
	}
	switch {
	case v.Setting == "disabled":
		return postActionResult{}, errPostActionClaimDisabled
	case v.Assigned > 0:
		return postActionResult{}, errPostActionClaimed
	case slices.Contains(input.IDs, 99):
		return postActionResult{}, errPostActionMissing
	case input.Action == "reject" && input.Note == "":
		return postActionResult{}, errPostActionNote
	case v.AuditFail > 0:
		return postActionResult{}, errSessionStore
	case v.Processed > 0 && input.Bulk && slices.Equal(input.IDs, []int64{81, 82}) && input.Action == "approve":
		return postActionResult{Count: len(input.IDs)}, nil
	case v.Item != nil && len(input.IDs) == 1 && input.IDs[0] == v.Item.PostID && moderationPostActions.Actions[input.Action].Status == v.Item.Status:
		if input.Action == "reject" && (input.Note != "Reviewed" || input.Reason != "duplicate") {
			return postActionResult{}, errSessionStore
		}
		return postActionResult{Item: *v.Item}, nil
	default:
		return postActionResult{}, errSessionStore
	}
}

func TestNativeModerationPostActions(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/moderation-post-actions.json")
	if err != nil {
		t.Fatal(err)
	}
	var spec struct{ Cases []postActionVector }
	if err := json.Unmarshal(raw, &spec); err != nil {
		t.Fatal(err)
	}
	codec, tokens := fixture(t)
	repo := &postActionFixture{dashboardFixture: &dashboardFixture{memorySessions: store()}}
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
			var payload struct {
				Data struct {
					Processed int `json:"processed_count"`
					contentQueueItem
				}
			}
			if v.Status == 200 {
				if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
					t.Fatal(err)
				}
				if payload.Data.Processed != v.Processed || v.Item != nil && !reflect.DeepEqual(payload.Data.contentQueueItem, *v.Item) {
					t.Fatal(response.Body.String())
				}
			}
		})
	}
}

type postActionTxConnector struct {
	resetTransactionConnector
	fail  bool
	locks *[]int64
}

type postActionTxConn struct {
	*resetTransactionConn
	config  postActionTxConnector
	created bool
}

func (c postActionTxConnector) Connect(context.Context) (driver.Conn, error) {
	return &postActionTxConn{resetTransactionConn: &resetTransactionConn{testConn: &testConn{state: &c.state.driverState}, state: c.state}, config: c}, nil
}

func (c *postActionTxConn) QueryContext(_ context.Context, q string, binds []driver.NamedValue) (driver.Rows, error) {
	var row appealRows
	switch q {
	case moderationPostActions.SQL["settings"]:
	case moderationPostActions.SQL["post"]:
		id := binds[0].Value.(int64)
		*c.config.locks = append(*c.config.locks, id)
		row = appealRows{id}
	case moderationPostActions.SQL["case"]:
		id := binds[0].Value.(int64)
		if id == 81 || c.created {
			row = appealRows{id - 64, nil}
		}
	default:
		return nil, errors.New("unexpected query")
	}
	return &row, nil
}

func (c *postActionTxConn) ExecContext(_ context.Context, q string, binds []driver.NamedValue) (driver.Result, error) {
	c.state.queries = append(c.state.queries, q)
	if q == moderationPostActions.SQL["create"] {
		c.created = true
	}
	if c.config.fail && q == moderationPostActions.SQL["audit"] && binds[1].Value == int64(82) {
		return nil, errors.New("isolated audit failure")
	}
	return driver.RowsAffected(1), nil
}

func TestBulkPostModerationRollsBackWriteAndAudit(t *testing.T) {
	for _, fail := range []bool{false, true} {
		t.Run(map[bool]string{false: "commit", true: "audit failure"}[fail], func(t *testing.T) {
			state := &resetTransactionState{}
			var locks []int64
			db := sql.OpenDB(postActionTxConnector{resetTransactionConnector{state}, fail, &locks})
			defer db.Close()
			input, _ := parsePostAction(map[string]any{"post_ids": []any{82.0, "81", 81.0}, "action": "approve"}, "", true)
			result, err := (OracleSessions{DB: db}).ModeratePosts(context.Background(), 42, input, StorageURLPolicy{})
			if fail {
				if err == nil || state.commits != 0 || state.rollbacks != 1 {
					t.Fatal(result, err, state.commits, state.rollbacks)
				}
			} else if err != nil || result.Count != 2 || state.commits != 1 || state.rollbacks != 0 {
				t.Fatal(result, err, state.commits, state.rollbacks)
			}
			if !slices.Equal(locks, []int64{81, 82}) || len(state.queries) != 9 {
				t.Fatal(locks, state.queries)
			}
		})
	}
}
