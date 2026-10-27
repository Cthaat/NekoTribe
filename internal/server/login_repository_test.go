package server

import (
	"context"
	"database/sql"
	"strings"
	"testing"
	"time"
)

func TestLoginOracleWritesUseBoundValuesAndCommit(t *testing.T) {
	state := &driverState{}
	db := sql.OpenDB(testConnector{state})
	defer db.Close()
	repo := OracleSessions{db}
	ctx := context.Background()
	now := time.Unix(1700000000, 0)
	for _, tc := range []struct {
		name, fragment string
		run            func() error
		expected       map[string]interface{}
	}{
		{"session", "INSERT INTO n_auth_sessions", func() error {
			return repo.InsertLoginSession(ctx, LoginSession{UserID: 42, SessionID: "sess-opaque';--", AccessJTI: "jti", RefreshHash: "hash", DeviceInfo: "device", DeviceFingerprint: "fp", IPAddress: "ip", UserAgent: "agent", AccessExpiresAt: now, RefreshExpiresAt: now.Add(time.Hour)})
		}, map[string]interface{}{"session_id": "sess-opaque';--", "user_id": int64(42), "access_jti": "jti", "refresh_token_hash": "hash", "device_info": "device", "device_fingerprint": "fp", "ip_address": "ip", "user_agent": "agent", "access_token_expires_at": now, "refresh_token_expires_at": now.Add(time.Hour)}},
		{"last-login", "UPDATE n_users", func() error { return repo.UpdateLastLogin(ctx, 42) }, map[string]interface{}{"user_id": int64(42)}},
		{"challenge", "INSERT INTO n_auth_two_factor_challenges", func() error {
			return repo.CreateLoginChallenge(ctx, LoginChallenge{ID: "2fa-id';--", UserID: 42, Remember: true, DeviceInfo: "device", Fingerprint: "fp", IPAddress: "ip", UserAgent: "agent", ExpiresAt: now})
		}, map[string]interface{}{"challenge_id": "2fa-id';--", "user_id": int64(42), "remember_me": int64(1), "device_info": "device", "device_fingerprint": "fp", "ip_address": "ip", "user_agent": "agent", "expires_at": now}},
		{"consume challenge", "consumed_at IS NULL", func() error { _, err := repo.ConsumeLoginChallenge(ctx, "2fa-id';--"); return err }, map[string]interface{}{"challenge_id": "2fa-id';--"}},
		{"consume recovery", "used_at IS NULL", func() error { _, err := repo.ConsumeRecoveryCode(ctx, 42); return err }, map[string]interface{}{"recovery_code_id": int64(42)}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			before := state.commits
			if err := tc.run(); err != nil {
				t.Fatal(err)
			}
			if state.commits != before+1 || !strings.Contains(state.sql, tc.fragment) || strings.Contains(state.sql, "';--") {
				t.Fatal("unsafe SQL or missing commit")
			}
			for _, arg := range state.args {
				if tc.expected[arg.Name] != arg.Value {
					t.Fatalf("binding %s: %v", arg.Name, arg.Value)
				}
				delete(tc.expected, arg.Name)
			}
			if len(tc.expected) > 0 {
				t.Fatalf("missing binds %v", tc.expected)
			}
		})
	}
}
func TestLoginOracleWriteFailureRedacted(t *testing.T) {
	for _, fault := range []string{"connect", "execute", "commit"} {
		t.Run(fault, func(t *testing.T) {
			state := &driverState{fail: fault}
			db := sql.OpenDB(testConnector{state})
			defer db.Close()
			err := (OracleSessions{db}).CreateLoginChallenge(context.Background(), LoginChallenge{})
			if err == nil || strings.Contains(err.Error(), "private") {
				t.Fatal("unsafe failure", err)
			}
		})
	}
}
