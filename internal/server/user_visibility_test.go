package server

import (
	"bytes"
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
)

type visibilityFixture struct {
	*memorySessions
}

func TestBlockWriteRollsBackIfCancellingFollowFails(t *testing.T) {
	for _, fail := range []int{0, 2} {
		state := &resetTransactionState{claim: 1, user: 1, failAt: fail}
		state.queryRows = map[string]driver.Value{
			visibilitySQL["lockUser"]: int64(9), visibilitySQL["activeTarget"]: int64(9),
		}
		db := sql.OpenDB(resetTransactionConnector{state})
		found, err := (OracleSessions{db}).WriteUserVisibility(context.Background(), 42, 9, visibilityBlocks, false, nil)
		_ = db.Close()
		if len(state.queries) != 2 || state.queries[0] != visibilitySQL["block"] ||
			state.queries[1] != visibilitySQL["cancelFollows"] {
			t.Fatal("block and follow cancellation did not share the transaction")
		}
		if fail == 0 && (!found || err != nil || state.commits != 1) {
			t.Fatalf("block did not commit: %v", err)
		}
		if fail != 0 && (found || err == nil || state.commits != 0 || state.rollbacks != 1) {
			t.Fatalf("partial block was not rolled back: %v", err)
		}
	}
}

func (*visibilityFixture) ListUserVisibility(_ context.Context, actor int64, _ visibilityKind, page SessionPage) ([]visibilityItem, int64, error) {
	if actor != 42 || page.Start != 3 || page.End != 4 {
		return nil, 0, errSessionStore
	}
	return nil, 2, nil
}

func (*visibilityFixture) WriteUserVisibility(_ context.Context, actor, target int64, _ visibilityKind, remove bool, _ *string) (bool, error) {
	if actor != 42 {
		return false, errSessionStore
	}
	return remove || target == 9, nil
}

func TestUserVisibilityRoutes(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/user-visibility.json")
	if err != nil {
		t.Fatal(err)
	}
	var vectors struct {
		Cases []struct {
			ID, Method, Path, Relationship string
			Body                           json.RawMessage
			Status                         int
			ExpiresAt                      *string `json:"expires_at"`
		}
	}
	if err := json.Unmarshal(raw, &vectors); err != nil {
		t.Fatal(err)
	}
	codec, tokens := fixture(t)
	handler := NewHandler(codec, &visibilityFixture{memorySessions: store()}, CorsPolicy{})
	for _, vector := range vectors.Cases {
		t.Run(vector.ID, func(t *testing.T) {
			req := httptest.NewRequest(vector.Method, vector.Path, bytes.NewReader(vector.Body))
			req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			if vector.Body != nil {
				req.Header.Set("Content-Type", "application/json")
			}
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, req)
			if response.Code != vector.Status {
				t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
			}
			if vector.Status != http.StatusOK {
				return
			}
			var payload struct {
				Data json.RawMessage
				Meta map[string]any
			}
			if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
				t.Fatal(err)
			}
			if vector.Method == http.MethodGet {
				if string(payload.Data) != "[]" || payload.Meta["total"] != float64(2) ||
					response.Header().Get("Cache-Control") != "private, no-store" {
					t.Fatal(response.Body.String())
				}
				return
			}
			var data map[string]any
			if err := json.Unmarshal(payload.Data, &data); err != nil || data["relationship"] != vector.Relationship {
				t.Fatal(string(payload.Data), err)
			}
			expiry, present := data["expires_at"]
			if vector.ExpiresAt != nil && expiry != *vector.ExpiresAt ||
				vector.ExpiresAt == nil && (expiry != nil || present != (vector.Relationship == "muted")) {
				t.Fatal(string(payload.Data))
			}
		})
	}
}
