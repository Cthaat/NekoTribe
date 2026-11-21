package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"io"
	"strings"
	"testing"
)

type alertState struct {
	driverState
	known, alerts, email, push, enabled int64
	inactive                            bool
}
type alertConnector struct{ state *alertState }
type alertConn struct {
	*testConn
	state *alertState
}
type alertRows struct {
	values []driver.Value
	done   bool
}

func (c alertConnector) Connect(context.Context) (driver.Conn, error) {
	return &alertConn{testConn: &testConn{state: &c.state.driverState}, state: c.state}, nil
}
func (c alertConnector) Driver() driver.Driver { return testDriver{} }
func (c *alertConn) QueryContext(_ context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	c.state.sql = q
	c.state.args = args
	switch {
	case strings.Contains(q, "SELECT COUNT(*)"):
		return &alertRows{values: []driver.Value{c.state.known}}, nil
	case strings.Contains(q, "NVL(us.login_alerts"):
		if c.state.inactive {
			return &alertRows{}, nil
		}
		return &alertRows{values: []driver.Value{c.state.alerts, c.state.email, "recipient@example.test"}}, nil
	case strings.Contains(q, "NVL(us.push_notification_enabled"):
		if c.state.inactive {
			return emptyRows{&c.state.driverState}, nil
		}
		return &alertRows{values: []driver.Value{c.state.push, c.state.enabled}}, nil
	case strings.Contains(q, "seq_notification_id.NEXTVAL"):
		return &alertRows{values: []driver.Value{int64(44)}}, nil
	}
	return nil, errSessionStore
}
func (r *alertRows) Columns() []string {
	result := make([]string, len(r.values))
	for i := range result {
		result[i] = "value"
	}
	return result
}
func (*alertRows) Close() error { return nil }
func (r *alertRows) Next(dest []driver.Value) error {
	if r.done {
		return io.EOF
	}
	copy(dest, r.values)
	r.done = true
	return nil
}
func TestLoginAlertHonorsSettingsAndPersists(t *testing.T) {
	for _, tc := range []struct {
		name                         string
		alerts, email, push, enabled int64
		stored                       bool
	}{
		{"alerts disabled", 0, 1, 1, 1, false}, {"type disabled", 1, 1, 1, 0, false}, {"push disabled still stores", 1, 0, 0, 1, true}, {"enabled", 1, 1, 1, 1, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			state := &alertState{alerts: tc.alerts, email: tc.email, push: tc.push, enabled: tc.enabled}
			db := sql.OpenDB(alertConnector{state})
			defer db.Close()
			s := OracleSessions{db}
			v := LoginSession{UserID: 42, SessionID: "sess-id", DeviceInfo: "test-device", DeviceFingerprint: "fingerprint", IPAddress: "synthetic-ip", UserAgent: "synthetic-agent"}
			delivery, err := s.RecordLoginAlert(context.Background(), v)
			if err != nil {
				t.Fatal(err)
			}
			if got := delivery.Email != ""; got != (tc.alerts != 0 && tc.email != 0) {
				t.Errorf("email enabled=%v", got)
			}
			if got := delivery.NotificationID == 44; got != (tc.stored && tc.push != 0) {
				t.Errorf("push enabled=%v", got)
			}
			if (state.commits == 1) != tc.stored {
				t.Fatalf("stored=%v commits=%d", tc.stored, state.commits)
			}
			if tc.stored {
				if !strings.Contains(state.sql, "INSERT INTO n_notifications") {
					t.Fatal("missing notification insert")
				}
				var metadata string
				for _, a := range state.args {
					if a.Name == "metadata_json" {
						metadata, _ = a.Value.(string)
					}
				}
				if !strings.Contains(metadata, `"session_id":"sess-id"`) || !strings.Contains(metadata, `"device_fingerprint":"fingerprint"`) {
					t.Fatal("missing notification metadata")
				}
			}
		})
	}
}
func TestKnownLoginDeviceIsScopedByUserAndFingerprint(t *testing.T) {
	state := &alertState{known: 1}
	db := sql.OpenDB(alertConnector{state})
	defer db.Close()
	known, err := (OracleSessions{db}).KnownLoginDevice(context.Background(), 42, "device")
	if err != nil || !known {
		t.Fatal("known device not detected")
	}
	if !strings.Contains(state.sql, "user_id=:user_id") || !strings.Contains(state.sql, "device_fingerprint=:device_fingerprint") || len(state.args) != 2 {
		t.Fatal("missing identity binds")
	}
}
