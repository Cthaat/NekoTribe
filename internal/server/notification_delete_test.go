package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"strings"
	"testing"
)

type deleteNotificationFixture struct {
	*memorySessions
	user, id             int64
	restore, found, fail bool
	calls                int
}

func TestNotificationDeleteRepositoryScopesOperations(t *testing.T) {
	for _, tc := range []struct {
		name                 string
		restore              bool
		affected             int64
		missing, fail, found bool
	}{
		{"delete", false, 1, false, false, true}, {"delete already deleted", false, 0, false, false, false},
		{"delete row disappears", false, 1, true, false, true}, {"read fails after commit", false, 1, false, true, false},
		{"restore", true, 1, false, false, true}, {"restore other user", true, 0, false, false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			state := &readRepoState{affected: tc.affected, missing: tc.missing, queryFail: tc.fail}
			db := sql.OpenDB(readRepoConnector{state})
			defer db.Close()
			date, found, err := (OracleSessions{db}).SetNotificationDeleted(context.Background(), 42, 12, tc.restore)
			if found != tc.found || (err != nil) != tc.fail || state.commits != 1 {
				t.Fatalf("date=%v found=%v err=%v commits=%d", date, found, err, state.commits)
			}
			if !strings.Contains(state.written, "user_id=:user_id") || !strings.Contains(state.written, "notification_id=:notification_id") || strings.Contains(state.written, "deleted_at IS NULL") == tc.restore {
				t.Fatal(state.written)
			}
			args := map[string]any{}
			for _, arg := range state.bindings {
				args[arg.Name] = arg.Value
			}
			if args["user_id"] != int64(42) || args["notification_id"] != int64(12) {
				t.Fatal(args)
			}
			if tc.affected == 1 && !tc.restore {
				if !strings.Contains(state.query, "user_id=:user_id") || !strings.Contains(state.query, "notification_id=:notification_id") {
					t.Fatal(state.query)
				}
				if !tc.missing && !tc.fail && (date == nil || *date != "2026-01-02T03:04:05.000Z") {
					t.Fatal(date)
				}
			}
		})
	}
}

func (s *deleteNotificationFixture) SetNotificationDeleted(_ context.Context, user, id int64, restore bool) (*string, bool, error) {
	s.user, s.id, s.restore = user, id, restore
	s.calls++
	if s.fail {
		return nil, false, errors.New("private database failure")
	}
	if !s.found {
		return nil, false, nil
	}
	if restore {
		return nil, true, nil
	}
	date := "2026-01-02T03:04:05.000Z"
	return &date, true, nil
}

func TestNotificationDeleteAndRestore(t *testing.T) {
	codec, tokens := fixture(t)
	for _, tc := range []struct {
		name, method, path, token string
		found, fail, restore      bool
		status, calls, events     int
	}{
		{"unauthorized", "DELETE", "/api/v2/notifications/12", "", true, false, false, 401, 0, 0},
		{"invalid id", "DELETE", "/api/v2/notifications/01", tokens["access-hs256"], true, false, false, 400, 0, 0},
		{"delete", "DELETE", "/api/v2/notifications/12?user_id=99", tokens["access-hs256"], true, false, false, 200, 1, 1},
		{"missing or already deleted", "DELETE", "/api/v2/notifications/12", tokens["access-hs256"], false, false, false, 404, 1, 0},
		{"restore", "PUT", "/api/v2/notifications/12/restore-status", tokens["access-hs256"], true, false, true, 200, 1, 1},
		{"other user", "PUT", "/api/v2/notifications/12/restore-status", tokens["access-hs256"], false, false, true, 404, 1, 0},
		{"error", "DELETE", "/api/v2/notifications/12", tokens["access-hs256"], true, true, false, 500, 1, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := &deleteNotificationFixture{memorySessions: store(), found: tc.found, fail: tc.fail}
			pub := &likePublisher{}
			h := NewHandlerWithConfig(codec, s, CorsPolicy{}, RefreshConfig{NotificationPublisher: pub})
			r := httptest.NewRequest(tc.method, tc.path, nil)
			if tc.token != "" {
				r.Header.Set("Authorization", "Bearer "+tc.token)
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			if w.Code != tc.status || s.calls != tc.calls || pub.calls != tc.events || strings.Contains(w.Body.String(), "private database") {
				t.Fatalf("status=%d calls=%d events=%d body=%s", w.Code, s.calls, pub.calls, w.Body.String())
			}
			if w.Header().Get("Cache-Control") != "private, no-store" {
				t.Fatal(w.Header())
			}
			if tc.calls > 0 && (s.user != 42 || s.id != 12 || s.restore != tc.restore) {
				t.Fatal(s)
			}
			if tc.status == 200 {
				var response struct {
					Message string          `json:"message"`
					Data    json.RawMessage `json:"data"`
				}
				if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
					t.Fatal(err)
				}
				if tc.restore {
					if pub.kind != "notification_restored" || string(response.Data) != `{"deleted_at":null,"notification_id":12}` {
						t.Fatal(response, pub)
					}
				} else if pub.kind != "notification_deleted" || response.Message != "notification deleted" || string(response.Data) != "null" {
					t.Fatal(response, pub)
				}
				if pub.user != 42 || pub.data["notification_id"] != int64(12) {
					t.Fatal(pub)
				}
			}
		})
	}
}

func TestNotificationDeletePublisherFailureDoesNotUndoUpdate(t *testing.T) {
	codec, tokens := fixture(t)
	store := &deleteNotificationFixture{memorySessions: store(), found: true}
	publisher := &likePublisher{fail: true}
	h := NewHandlerWithConfig(codec, store, CorsPolicy{}, RefreshConfig{NotificationPublisher: publisher})
	r := httptest.NewRequest("DELETE", "/api/v2/notifications/12", nil)
	r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 200 || store.calls != 1 || publisher.calls != 1 {
		t.Fatalf("status=%d store=%d pub=%d", w.Code, store.calls, publisher.calls)
	}
}
