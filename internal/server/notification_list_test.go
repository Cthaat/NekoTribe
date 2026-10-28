package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"
)

type notificationFixture struct {
	*memorySessions
	viewer       int64
	query        NotificationQuery
	fail         bool
	actorMissing bool
	actorError   bool
}

func (s *notificationFixture) ListNotifications(_ context.Context, viewer int64, q NotificationQuery) ([]NotificationItem, int64, error) {
	s.viewer = viewer
	s.query = q
	if s.fail {
		return nil, 0, errors.New("private db error")
	}
	id := int64(7)
	return []NotificationItem{{ID: 12, Type: "like", ActorID: &id, Metadata: map[string]any{"event": "post_like"}}}, 3, nil
}
func (s *notificationFixture) PublicProfile(_ context.Context, viewer, target int64) (PublicUser, bool, error) {
	if s.actorError {
		return PublicUser{}, false, errors.New("private actor failure")
	}
	if viewer != 42 || target != 7 {
		return PublicUser{}, false, errors.New("wrong viewer")
	}
	return PublicUser{UserID: 7, Username: "actor"}, !s.actorMissing, nil
}

func TestNotificationHydrationUsesRecipientViewAndFailsSafely(t *testing.T) {
	s := &notificationFixture{memorySessions: store()}
	id := int64(7)
	item := NotificationItem{ID: 12, ActorID: &id}
	if err := hydrateNotification(context.Background(), s, 42, &item, StorageURLPolicy{}); err != nil || item.Actor == nil || item.Actor.UserID != 7 {
		t.Fatal(item, err)
	}
	s.actorError = true
	if err := hydrateNotification(context.Background(), s, 42, &item, StorageURLPolicy{}); err == nil || strings.Contains(err.Error(), "private actor failure") {
		t.Fatal(err)
	}
}
func TestNotificationListRouteScopesUserAndFilters(t *testing.T) {
	codec, tokens := fixture(t)
	s := &notificationFixture{memorySessions: store()}
	handler := NewHandler(codec, s, CorsPolicy{})
	for _, tc := range []struct {
		query, token string
		status       int
	}{
		{"", "", 401}, {"", "bad", 401},
		{"?type=like&unread_only=true&show_deleted=true&page=2&page_size=1&user_id=99", tokens["access-hs256"], 200},
	} {
		r := httptest.NewRequest("GET", "/api/v2/notifications"+tc.query, nil)
		if tc.token != "" {
			r.Header.Set("Authorization", "Bearer "+tc.token)
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Code != tc.status || w.Header().Get("Cache-Control") != "private, no-store" {
			t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
		}
		if tc.status == 200 {
			var body struct {
				Data []NotificationItem `json:"data"`
				Meta struct {
					Total   int  `json:"total"`
					HasNext bool `json:"has_next"`
				} `json:"meta"`
			}
			if json.Unmarshal(w.Body.Bytes(), &body) != nil || len(body.Data) != 1 || body.Data[0].Actor == nil || body.Data[0].Actor.UserID != 7 || body.Meta.Total != 3 || !body.Meta.HasNext {
				t.Fatal(w.Body.String())
			}
			if s.viewer != 42 || s.query.Type != "like" || !s.query.UnreadOnly || !s.query.ShowDeleted || s.query.Page.Start != 2 {
				t.Fatal(s.viewer, s.query)
			}
		}
	}
	s.actorMissing = true
	r := httptest.NewRequest("GET", "/api/v2/notifications", nil)
	r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	var missing struct {
		Data []NotificationItem `json:"data"`
	}
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &missing) != nil || len(missing.Data) != 1 || missing.Data[0].Actor != nil {
		t.Fatal(w.Code, w.Body.String())
	}
	s.fail = true
	r = httptest.NewRequest("GET", "/api/v2/notifications", nil)
	r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
	w = httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	if w.Code != 500 || strings.Contains(w.Body.String(), "private db error") {
		t.Fatal(w.Code, w.Body.String())
	}
}

type notificationConnector struct {
	calls    *[]listQueryCall
	state    *driverState
	metadata string
}
type notificationConn struct {
	*testConn
	connector notificationConnector
}

func (c notificationConnector) Connect(context.Context) (driver.Conn, error) {
	return &notificationConn{&testConn{c.state}, c}, nil
}
func (c notificationConnector) Driver() driver.Driver { return testDriver{} }
func (c *notificationConn) QueryContext(_ context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	*c.connector.calls = append(*c.connector.calls, listQueryCall{q, append([]driver.NamedValue(nil), args...)})
	if strings.HasPrefix(q, "SELECT COUNT") {
		return &alertRows{values: []driver.Value{int64(3)}}, nil
	}
	return &alertRows{values: []driver.Value{int64(12), int64(7), "like", "title", "message", "post", int64(9), "normal", int64(0), nil, nil, c.connector.metadata, time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)}}, nil
}
func TestNotificationRepositoryFiltersBindsAndMetadata(t *testing.T) {
	for _, metadata := range []string{`{"event":"post_like"}`, `invalid`, ``} {
		var calls []listQueryCall
		db := sql.OpenDB(notificationConnector{&calls, &driverState{}, metadata})
		q := parseNotificationQuery("type=like&unread_only=true&show_deleted=true&page=2&page_size=1")
		items, total, err := (OracleSessions{db}).ListNotifications(context.Background(), 42, q)
		db.Close()
		if err != nil || total != 3 || len(items) != 1 {
			t.Fatal(items, total, err)
		}
		if metadata == "invalid" && items[0].Metadata != "invalid" {
			t.Fatal(items[0].Metadata)
		}
		if metadata == "" && items[0].Metadata != nil {
			t.Fatal(items[0].Metadata)
		}
		if metadata != "" && metadata != "invalid" {
			m, ok := items[0].Metadata.(map[string]any)
			if !ok || m["event"] != "post_like" {
				t.Fatal(items[0].Metadata)
			}
		}
		for _, call := range calls {
			if !strings.Contains(call.sql, "user_id=:user_id") || !strings.Contains(call.sql, "deleted_at IS NOT NULL") || !strings.Contains(call.sql, "is_read=0") || !strings.Contains(call.sql, "type=:type") || strings.Contains(call.sql, "like") || call.args[0].Value != int64(42) || call.args[1].Value != "like" {
				t.Fatal(call)
			}
		}
	}
	q := parseNotificationQuery("type=like&type=other&unread_only=true&unread_only=false")
	if q.Type != "all" || q.UnreadOnly {
		t.Fatal(q)
	}
}

func TestNotificationByIDScopesRecipientAndUsesSameMappingAsList(t *testing.T) {
	var calls []listQueryCall
	db := sql.OpenDB(notificationConnector{&calls, &driverState{}, `{"event":"post_like"}`})
	defer db.Close()
	item, found, err := (OracleSessions{db}).NotificationByID(context.Background(), 42, 12)
	if err != nil || !found || item.ID != 12 || item.ActorID == nil || *item.ActorID != 7 {
		t.Fatalf("item=%+v found=%v err=%v", item, found, err)
	}
	metadata, ok := item.Metadata.(map[string]any)
	if !ok || metadata["event"] != "post_like" || item.ResourceType == nil || *item.ResourceType != "post" {
		t.Fatal(item)
	}
	if len(calls) != 1 || !strings.Contains(calls[0].sql, "user_id=:user_id") || !strings.Contains(calls[0].sql, "notification_id=:notification_id") {
		t.Fatal(calls)
	}
	bound := map[string]any{}
	for _, arg := range calls[0].args {
		bound[arg.Name] = arg.Value
	}
	if bound["user_id"] != int64(42) || bound["notification_id"] != int64(12) {
		t.Fatal(bound)
	}
	items, _, err := (OracleSessions{db}).ListNotifications(context.Background(), 42, parseNotificationQuery(""))
	if err != nil || len(items) != 1 || !reflect.DeepEqual(item, items[0]) {
		t.Fatalf("lookup and list mappings diverged: lookup=%+v list=%+v err=%v", item, items, err)
	}
}

type notificationLookupConnector struct {
	state *driverState
	fail  bool
}
type notificationLookupConn struct {
	*testConn
	fail bool
}

func (c notificationLookupConnector) Connect(context.Context) (driver.Conn, error) {
	return &notificationLookupConn{&testConn{c.state}, c.fail}, nil
}
func (c notificationLookupConnector) Driver() driver.Driver { return testDriver{} }
func (c *notificationLookupConn) QueryContext(context.Context, string, []driver.NamedValue) (driver.Rows, error) {
	if c.fail {
		return nil, errors.New("private lookup error")
	}
	return emptyRows{c.state}, nil
}
func TestNotificationByIDMissingAndDatabaseErrors(t *testing.T) {
	for _, fail := range []bool{false, true} {
		db := sql.OpenDB(notificationLookupConnector{&driverState{}, fail})
		item, found, err := (OracleSessions{db}).NotificationByID(context.Background(), 42, 12)
		db.Close()
		if found || item.ID != 0 || (!fail && err != nil) || (fail && err != errSessionStore) {
			t.Fatalf("fail=%v item=%+v found=%v err=%v", fail, item, found, err)
		}
	}
}

func TestNotificationLookupPreservesUTF16ExcerptEscape(t *testing.T) {
	var calls []listQueryCall
	db := sql.OpenDB(notificationConnector{&calls, &driverState{}, `{"post_excerpt":"prefix\ud83d..."}`})
	defer db.Close()
	item, found, err := (OracleSessions{db}).NotificationByID(context.Background(), 42, 12)
	if err != nil || !found {
		t.Fatal(found, err)
	}
	encoded, err := json.Marshal(item)
	if err != nil || !strings.Contains(string(encoded), `"post_excerpt":"prefix\ud83d..."`) {
		t.Fatal(string(encoded), err)
	}
	_, event, err := buildNotificationEvent(42, "notification_created", map[string]interface{}{"notification": item}, "server", 1)
	if err != nil || !strings.Contains(string(event), `"post_excerpt":"prefix\ud83d..."`) {
		t.Fatal(string(event), err)
	}
}
