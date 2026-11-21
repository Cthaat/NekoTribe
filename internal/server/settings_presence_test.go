package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"
)

func presenceVectors(t *testing.T) []byte {
	t.Helper()
	raw, err := os.ReadFile("../../contracts/scenarios/user-settings-presence.json")
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

type presenceFlowStore struct {
	*settingsRouteStore
	oracle OracleSessions
	state  *settingsDBState
	t      *testing.T
}

func (s *presenceFlowStore) PatchUserSettings(ctx context.Context, user int64, patch settingsPatch) (userSettings, error) {
	return s.oracle.applyUserSettings(ctx, user, &patch, func(context.Context, *sql.Conn) error { return nil })
}
func (s *presenceFlowStore) UserPresence(ctx context.Context, user int64) (userPresence, error) {
	if s.state.commits != 1 {
		s.t.Error("presence queried before commit")
	}
	return s.oracle.UserPresence(ctx, user)
}

func TestSharedSettingsPresenceHTTP(t *testing.T) {
	var vectors struct {
		Cases []struct {
			ID, Mode                 string
			Body                     json.RawMessage
			Status, Reads, Publishes int
			ExpectedStatus           string
			ExpectedLastSeen         *string
		}
	}
	if err := json.Unmarshal(presenceVectors(t), &vectors); err != nil {
		t.Fatal(err)
	}
	codec, tokens := fixture(t)
	for _, tc := range vectors.Cases {
		t.Run(tc.ID, func(t *testing.T) {
			state := &settingsDBState{}
			switch tc.Mode {
			case "hidden":
				state.mode = "presence-hidden"
			case "lookup-error":
				state.mode = "presence-error"
			case "store-error":
				state.mode = "update"
			}
			db := sql.OpenDB(settingsConnector{state})
			defer db.Close()
			repository := &presenceFlowStore{settingsRouteStore: &settingsRouteStore{memorySessions: store()}, oracle: OracleSessions{db}, state: state, t: t}
			fake := &eventFake{fail: tc.Mode == "publish-error"}
			publisher := &UserEventPublisher{client: fake, serverID: "test-instance", clock: func() time.Time { return time.UnixMilli(1700000000000) }}
			config := RefreshConfig{}
			if tc.Mode != "publisher-absent" {
				config.PresencePublisher = publisher
			}
			req := httptest.NewRequest("PATCH", "/api/v2/users/me/settings", strings.NewReader(string(tc.Body)))
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			w := httptest.NewRecorder()
			NewHandlerWithConfig(codec, repository, CorsPolicy{}, config).ServeHTTP(w, req)
			if w.Code != tc.Status || w.Header().Get("Cache-Control") != "private, no-store" || state.presenceReads != tc.Reads || fake.calls != tc.Publishes || strings.Contains(w.Body.String(), "secret") {
				t.Fatal(w.Code, w.Body.String(), state, fake.calls)
			}
			expectedCommits := 0
			if tc.Status == 200 || tc.Mode == "lookup-error" {
				expectedCommits = 1
			}
			if state.commits != expectedCommits {
				t.Fatal("wrong commit boundary", state)
			}
			if tc.Mode == "lookup-error" && state.rollbacks != 0 {
				t.Fatal("post-commit read failure claimed rollback")
			}
			if tc.ExpectedStatus != "" {
				var frame struct {
					Type      string
					Data      userPresence
					Timestamp int64
				}
				if json.Unmarshal(fake.payload, &frame) != nil || fake.channel != "ws:presence" || frame.Type != "presence_update" || frame.Data.UserID != 42 || frame.Data.OnlineStatus != tc.ExpectedStatus || !reflect.DeepEqual(frame.Data.LastSeenAt, tc.ExpectedLastSeen) {
					t.Fatal(string(fake.payload))
				}
			}
		})
	}
}

func TestSharedPresenceQuery(t *testing.T) {
	var vectors struct {
		QueryCases []struct {
			ID               string
			Flag             float64
			Status           string
			LastSeen         *string
			Missing, Error   bool
			ExpectedStatus   string
			ExpectedLastSeen *string
		}
	}
	if err := json.Unmarshal(presenceVectors(t), &vectors); err != nil {
		t.Fatal(err)
	}
	for _, tc := range vectors.QueryCases {
		t.Run(tc.ID, func(t *testing.T) {
			var seen driver.Value
			if tc.LastSeen != nil {
				parsed, err := time.Parse(time.RFC3339Nano, *tc.LastSeen)
				if err != nil {
					t.Fatal(err)
				}
				seen = parsed
			}
			state := &settingsDBState{presenceValues: []driver.Value{tc.Flag, seen, tc.Status}}
			if tc.Missing {
				state.mode = "presence-missing"
			}
			db := sql.OpenDB(settingsConnector{state})
			defer db.Close()
			got, err := (OracleSessions{db}).UserPresence(context.Background(), 42)
			if tc.Error {
				if err == nil {
					t.Fatal(got)
				}
				return
			}
			if err != nil || got.UserID != 42 || got.OnlineStatus != tc.ExpectedStatus || !reflect.DeepEqual(got.LastSeenAt, tc.ExpectedLastSeen) {
				t.Fatal(got, err)
			}
			if !strings.Contains(state.calls[0].sql, "NUMTODSINTERVAL(90") || !strings.Contains(state.calls[0].sql, "revoked_at IS NULL") {
				t.Fatal("presence query semantics", state.calls)
			}
		})
	}
}

func TestSharedPresenceEvent(t *testing.T) {
	var vectors struct {
		EventCases []struct {
			ID, ServerID string
			Data         json.RawMessage
			Timestamp    int64
			Valid        bool
		}
	}
	if err := json.Unmarshal(presenceVectors(t), &vectors); err != nil {
		t.Fatal(err)
	}
	for _, tc := range vectors.EventCases {
		t.Run(tc.ID, func(t *testing.T) {
			var raw map[string]json.RawMessage
			if json.Unmarshal(tc.Data, &raw) != nil {
				t.Fatal("invalid vector")
			}
			var status string
			json.Unmarshal(raw["online_status"], &status)
			if status == "hidden" {
				raw["last_seen_at"] = json.RawMessage("null")
			}
			bytes, _ := json.Marshal(raw)
			var input userPresence
			if err := json.Unmarshal(bytes, &input); err != nil {
				if tc.Valid {
					t.Fatal(err)
				}
				return
			}
			fake := &eventFake{}
			publisher := &UserEventPublisher{client: fake, serverID: tc.ServerID, clock: func() time.Time { return time.UnixMilli(tc.Timestamp) }}
			err := publisher.PublishPresence(context.Background(), input)
			if (err == nil) != tc.Valid {
				t.Fatal(err, string(fake.payload))
			}
			if tc.Valid {
				var frame map[string]interface{}
				if json.Unmarshal(fake.payload, &frame) != nil {
					t.Fatal("invalid frame")
				}
				data := frame["data"].(map[string]interface{})
				if len(data) != 4 || data["server_id"] != tc.ServerID || data["online_status"] != status {
					t.Fatal(data)
				}
				if status == "hidden" && data["last_seen_at"] != nil {
					t.Fatal("hidden timestamp leaked")
				}
			} else if fake.calls != 0 {
				t.Fatal("invalid event published")
			}
		})
	}
}
