package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"io"
	"strings"
	"testing"
	"time"
)

type loginGuardRow struct {
	value driver.Value
	read  bool
}

func (*loginGuardRow) Columns() []string { return []string{"VALUE"} }
func (*loginGuardRow) Close() error      { return nil }
func (r *loginGuardRow) Next(dest []driver.Value) error {
	if r.read {
		return io.EOF
	}
	r.read = true
	dest[0] = r.value
	return nil
}

func TestLoginOracleCredentialGuard(t *testing.T) {
	for _, current := range []string{"accepted-hash", "changed-hash"} {
		t.Run(current, func(t *testing.T) {
			state := &driverState{queryRows: map[string]driver.Value{
				lockLoginUserSQL:    int64(42),
				currentLoginHashSQL: current,
			}}
			db := sql.OpenDB(testConnector{state})
			defer db.Close()
			repo := OracleSessions{db}
			hash := "accepted-hash"
			_, err := repo.InsertLoginSession(context.Background(), LoginSession{
				UserID: 42, verifiedPasswordHash: hash,
			})
			if current == hash {
				if err != nil || state.sql != insertLoginSessionSQL || state.commits != 1 {
					t.Fatalf("missing committed session: %v", err)
				}
			} else if !errors.Is(err, errLoginCredentialsChanged) || state.sql != currentLoginHashSQL ||
				state.commits != 0 || state.rollbacks != 1 {
				t.Fatalf("changed credential was not rejected and rolled back: %v", err)
			}
		})
	}
}

func TestLoginOracleUnusableDeviceRollsBackBeforeSession(t *testing.T) {
	state := &driverState{
		fail:      "trusted-device-unavailable",
		queryRows: map[string]driver.Value{lockLoginUserSQL: int64(42), currentLoginHashSQL: "accepted-hash"},
	}
	db := sql.OpenDB(testConnector{state})
	defer db.Close()
	_, err := (OracleSessions{db}).InsertLoginSession(context.Background(), LoginSession{
		UserID: 42, verifiedPasswordHash: "accepted-hash", trustedDeviceKey: "stored-digest",
	})
	if !errors.Is(err, errTrustedDeviceUnavailable) || state.sql != claimTrustedDeviceSQL ||
		state.commits != 0 || state.rollbacks != 1 {
		t.Fatalf("session write should stop at the device claim: %v", err)
	}
}

func TestLoginOracleFactorCompletionRollsBackWhenSessionWriteFails(t *testing.T) {
	state := &driverState{
		fail: "factor-session-write",
		queryRows: map[string]driver.Value{
			lockLoginUserSQL: int64(42), currentLoginHashSQL: "accepted-hash", trustedDeviceSequenceSQL: int64(5),
			lockLoginFactorSQL: int64(42), currentLoginFactorSQL: int64(42),
		},
	}
	db := sql.OpenDB(testConnector{state})
	defer db.Close()
	recoveryID := int64(23)
	_, err := (OracleSessions{db}).InsertLoginSession(context.Background(), LoginSession{
		UserID: 42, verifiedPasswordHash: "accepted-hash",
		factorCompletion: &factorCompletion{
			challenge: LoginChallenge{ID: "existing-challenge"}, recoveryCodeID: &recoveryID,
			trustedKey: "stored-digest", trustedExpiry: time.Unix(1800000000, 0),
		},
	})
	if !errors.Is(err, errSessionStore) || state.sql != insertLoginSessionSQL ||
		state.commits != 0 || state.rollbacks != 1 {
		t.Fatalf("partial factor login did not roll back: %v", err)
	}
}

func TestLoginOracleFactorChangedBeforeCompletion(t *testing.T) {
	state := &driverState{queryRows: map[string]driver.Value{
		lockLoginUserSQL: int64(42), currentLoginHashSQL: "accepted-hash", lockLoginFactorSQL: int64(42),
	}}
	db := sql.OpenDB(testConnector{state})
	defer db.Close()
	session := LoginSession{
		UserID: 42, verifiedPasswordHash: "accepted-hash",
		factorCompletion: &factorCompletion{verifiedSecret: FactorSecret{Encrypted: "verified-fixture"}},
	}
	_, err := (OracleSessions{db}).InsertLoginSession(context.Background(), session)
	if !errors.Is(err, errFactorCompletionUnavailable) || state.sql != currentLoginFactorSQL ||
		state.commits != 0 || state.rollbacks != 1 {
		t.Fatalf("changed factor did not stop the login: %v", err)
	}
}

func TestLoginOracleWritesUseBoundValuesAndCommit(t *testing.T) {
	state := &driverState{queryRows: map[string]driver.Value{lockLoginUserSQL: int64(42), currentLoginHashSQL: "synthetic-hash"}}
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
			_, err := repo.InsertLoginSession(ctx, LoginSession{UserID: 42, verifiedPasswordHash: "synthetic-hash", SessionID: "sess-opaque';--", AccessJTI: "jti", RefreshHash: "hash", DeviceInfo: "device", DeviceFingerprint: "fp", IPAddress: "ip", UserAgent: "agent", AccessExpiresAt: now, RefreshExpiresAt: now.Add(time.Hour)})
			return err
		}, map[string]interface{}{"session_id": "sess-opaque';--", "user_id": int64(42), "access_jti": "jti", "refresh_token_hash": "hash", "device_info": "device", "device_fingerprint": "fp", "ip_address": "ip", "user_agent": "agent", "access_token_expires_at": "2023-11-14T22:13:20.000+00:00", "refresh_token_expires_at": "2023-11-14T23:13:20.000+00:00"}},
		{"last-login", "UPDATE n_users", func() error { return repo.UpdateLastLogin(ctx, 42) }, map[string]interface{}{"user_id": int64(42)}},
		{"challenge", "INSERT INTO n_auth_two_factor_challenges", func() error {
			return repo.CreateLoginChallenge(ctx, LoginChallenge{ID: "2fa-id';--", UserID: 42, verifiedPasswordHash: "synthetic-hash", Remember: true, DeviceInfo: "device", Fingerprint: "fp", IPAddress: "ip", UserAgent: "agent", ExpiresAt: now})
		}, map[string]interface{}{"challenge_id": "2fa-id';--", "user_id": int64(42), "remember_me": int64(1), "device_info": "device", "device_fingerprint": "fp", "ip_address": "ip", "user_agent": "agent", "expires_at": now}},
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
			state := &driverState{fail: fault, queryRows: map[string]driver.Value{lockLoginUserSQL: int64(42), currentLoginHashSQL: "synthetic-hash"}}
			db := sql.OpenDB(testConnector{state})
			defer db.Close()
			err := (OracleSessions{db}).CreateLoginChallenge(context.Background(), LoginChallenge{UserID: 42, verifiedPasswordHash: "synthetic-hash"})
			if err == nil || strings.Contains(err.Error(), "private") {
				t.Fatal("unsafe failure", err)
			}
		})
	}
}
