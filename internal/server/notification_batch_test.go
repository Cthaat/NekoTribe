package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
)

type batchReadFixture struct {
	*memorySessions
	user  int64
	ids   []int64
	read  bool
	calls int
	fail  bool
}

func TestNotificationBatchRepositoryScopesAllAndSelection(t *testing.T) {
	for _, tc := range []struct {
		name    string
		ids     []int64
		commits int
		all     bool
	}{{"all", nil, 1, true}, {"selection", []int64{7, 7, 8}, 3, false}} {
		t.Run(tc.name, func(t *testing.T) {
			state := &readRepoState{affected: 1}
			db := sql.OpenDB(readRepoConnector{state})
			defer db.Close()
			count, err := (OracleSessions{db}).BatchSetNotificationRead(context.Background(), 42, tc.ids, true)
			if err != nil || count != int64(tc.commits) || state.commits != tc.commits {
				t.Fatalf("count=%d commits=%d err=%v", count, state.commits, err)
			}
			if !strings.Contains(state.written, "user_id=:user_id") || strings.Contains(state.written, "deleted_at IS NULL") != tc.all {
				t.Fatal(state.written)
			}
			args := map[string]any{}
			for _, arg := range state.bindings {
				args[arg.Name] = arg.Value
			}
			if args["user_id"] != int64(42) || args["is_read"] != int64(1) {
				t.Fatal(args)
			}
			if !tc.all && args["notification_id"] != int64(8) {
				t.Fatal(args)
			}
		})
	}
}

func TestNotificationBatchRepositoryFailureLeavesEarlierCommit(t *testing.T) {
	state := &readRepoState{affected: 1, failExecAt: 2}
	db := sql.OpenDB(readRepoConnector{state})
	defer db.Close()
	_, err := (OracleSessions{db}).BatchSetNotificationRead(context.Background(), 42, []int64{7, 8, 9}, true)
	if err == nil || state.execCalls != 2 || state.commits != 1 {
		t.Fatalf("err=%v calls=%d commits=%d", err, state.execCalls, state.commits)
	}
}

func (s *batchReadFixture) BatchSetNotificationRead(_ context.Context, user int64, ids []int64, read bool) (int64, error) {
	s.user, s.ids, s.read = user, ids, read
	s.calls++
	if s.fail {
		return 0, errors.New("private database error")
	}
	if len(ids) == 0 {
		return 4, nil
	}
	return int64(len(ids)), nil
}

func TestNotificationBatchRead(t *testing.T) {
	codec, tokens := fixture(t)
	for _, tc := range []struct {
		name, body, token string
		status, calls     int
		ids               []int64
		read, fail        bool
	}{
		{"unauthorized", `{}`, "", 401, 0, nil, false, false},
		{"all", `{"is_read":true}`, tokens["access-hs256"], 200, 1, nil, true, false},
		{"empty", `{"notification_ids":[],"is_read":false}`, tokens["access-hs256"], 200, 1, []int64{}, false, false},
		{"selection", `{"notification_ids":[7,7,8],"is_read":true,"user_id":99}`, tokens["access-hs256"], 200, 1, []int64{7, 7, 8}, true, false},
		{"invalid string", `{"notification_ids":"oops"}`, tokens["access-hs256"], 400, 0, nil, false, false},
		{"invalid null", `{"notification_ids":null}`, tokens["access-hs256"], 400, 0, nil, false, false},
		{"invalid element", `{"notification_ids":[1,null]}`, tokens["access-hs256"], 400, 0, nil, false, false},
		{"fraction", `{"notification_ids":[1.5]}`, tokens["access-hs256"], 400, 0, nil, false, false},
		{"too large", `{"notification_ids":[9007199254740992]}`, tokens["access-hs256"], 400, 0, nil, false, false},
		{"db error", `{"notification_ids":[7]}`, tokens["access-hs256"], 500, 1, []int64{7}, false, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := &batchReadFixture{memorySessions: store(), fail: tc.fail}
			pub := &likePublisher{}
			h := NewHandlerWithConfig(codec, s, CorsPolicy{}, RefreshConfig{NotificationPublisher: pub})
			r := httptest.NewRequest("PUT", "/api/v2/notifications/read-status", strings.NewReader(tc.body))
			r.Header.Set("Content-Type", "application/json")
			if tc.token != "" {
				r.Header.Set("Authorization", "Bearer "+tc.token)
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			if w.Code != tc.status || s.calls != tc.calls || strings.Contains(w.Body.String(), "private database") {
				t.Fatalf("status=%d calls=%d body=%s", w.Code, s.calls, w.Body.String())
			}
			if tc.calls != 0 && (s.user != 42 || !reflect.DeepEqual(s.ids, tc.ids) || s.read != tc.read) {
				t.Fatalf("store: %+v", s)
			}
			if tc.status == 200 {
				var result struct {
					Data struct {
						UpdatedCount int64 `json:"updated_count"`
					} `json:"data"`
				}
				if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil || pub.calls != 1 || result.Data.UpdatedCount == 0 {
					t.Fatalf("result=%+v publisher=%+v error=%v", result, pub, err)
				}
				if pub.user != 42 || pub.kind != "notifications_read_status_updated" || pub.data["updated_count"] != result.Data.UpdatedCount || pub.data["is_read"] != int64(boolNumber(tc.read)) {
					t.Fatalf("incorrect event: %+v", pub)
				}
				if len(tc.ids) == 0 && pub.data["all"] != true {
					t.Fatal(pub.data)
				}
				if len(tc.ids) > 0 && !reflect.DeepEqual(pub.data["notification_ids"], tc.ids) {
					t.Fatal(pub.data)
				}
			} else if pub.calls != 0 {
				t.Fatalf("unexpected event: %+v", pub)
			}
		})
	}
}
