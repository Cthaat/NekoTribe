package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
)

type followFixture struct {
	*memorySessions
	following bool
	notices   int
}

func (*followFixture) ListUserFollows(_ context.Context, actor, target int64, _ string, page SessionPage) ([]visibilityItem, int64, error) {
	if actor != 42 || target != 9 || page.Start != 3 {
		return nil, 0, errSessionStore
	}
	return nil, 2, nil
}
func (f *followFixture) WriteUserFollow(_ context.Context, _ int64, target int64, remove bool) (int64, bool, error) {
	if target == 7 {
		return 0, false, errFollowBlocked
	}
	if target == 81 && !remove {
		return 0, false, errFollowMissing
	}
	inserted := !remove && !f.following
	f.following = !remove
	if f.following {
		return 1, inserted, nil
	}
	return 0, false, nil
}
func (f *followFixture) PrepareFollowNotification(context.Context, int64, int64) (*notificationStored, error) {
	f.notices++
	if !f.following {
		return nil, errSessionStore
	}
	return nil, nil
}
func (*followFixture) NotificationByID(context.Context, int64, int64) (NotificationItem, bool, error) {
	return NotificationItem{}, false, errSessionStore
}

func TestSharedFollowRoutes(t *testing.T) {
	content, err := os.ReadFile("../../contracts/scenarios/user-follow.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixtureData struct {
		Cases []struct {
			ID, Method, Path, Relationship string
			Status, Count                  int
			Notify                         bool
		}
	}
	if err := json.Unmarshal(content, &fixtureData); err != nil {
		t.Fatal(err)
	}
	codec, tokens := fixture(t)
	f := &followFixture{memorySessions: store()}
	handler := NewHandler(codec, f, CorsPolicy{})
	for _, item := range fixtureData.Cases {
		t.Run(item.ID, func(t *testing.T) {
			before := f.notices
			req := httptest.NewRequest(item.Method, item.Path, nil)
			if item.ID != "anonymous" {
				req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			}
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, req)
			if response.Code != item.Status || item.Notify != (f.notices-before == 1) {
				t.Fatal(response.Code, response.Body.String(), f.notices-before)
			}
			var p struct {
				Data struct {
					Relationship string
					Count        int `json:"followers_count"`
				}
			}
			if item.Relationship != "" {
				if err := json.Unmarshal(response.Body.Bytes(), &p); err != nil || p.Data.Relationship != item.Relationship || p.Data.Count != item.Count {
					t.Fatal(response.Body.String(), err)
				}
			} else if item.Status == http.StatusOK && response.Header().Get("Cache-Control") != "private, no-store" {
				t.Fatal("relationship response cached")
			}
		})
	}
}

func TestFollowWriteRejectsBlockBeforeMutation(t *testing.T) {
	for _, blocked := range []int64{0, 1} {
		state := &resetTransactionState{claim: 1}
		state.queryRows = map[string]driver.Value{
			visibilitySQL["lockUser"]: int64(9), visibilitySQL["activeTarget"]: int64(9),
			visibilitySQL["blocked"]: blocked, visibilitySQL["followCount"]: int64(1),
		}
		db := sql.OpenDB(resetTransactionConnector{state})
		count, inserted, err := (OracleSessions{db}).WriteUserFollow(context.Background(), 42, 9, false)
		_ = db.Close()
		if blocked != 0 {
			if !errors.Is(err, errFollowBlocked) || state.rollbacks != 1 || len(state.queries) != 0 {
				t.Fatal("blocked follow wrote state", err, state.queries)
			}
		} else if err != nil || count != 1 || !inserted || state.commits != 1 || len(state.queries) != 1 {
			t.Fatal("valid follow did not commit correctly", err)
		}
	}
}
