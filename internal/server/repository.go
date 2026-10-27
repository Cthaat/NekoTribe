package server

import (
	"context"
	"database/sql"
	"errors"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

const TouchSQL = `UPDATE n_auth_sessions
SET last_accessed_at = CURRENT_TIMESTAMP
WHERE user_id = :user_id AND session_id = :session_id AND access_jti = :access_jti
AND revoked_at IS NULL AND access_token_expires_at > CURRENT_TIMESTAMP`
const RevokeSQL = `UPDATE n_auth_sessions SET revoked_at = CURRENT_TIMESTAMP
WHERE user_id = :user_id AND session_id = :session_id AND revoked_at IS NULL`
const RevokeOthersSQL = `UPDATE n_auth_sessions SET revoked_at = CURRENT_TIMESTAMP
WHERE user_id = :user_id AND session_id <> :session_id AND revoked_at IS NULL`
const LogoutRefreshSQL = `UPDATE n_auth_sessions SET revoked_at = CURRENT_TIMESTAMP
WHERE session_id = :session_id AND user_id = :user_id AND revoked_at IS NULL
AND refresh_token_hash = :refresh_token_hash`
const LogoutAccessSQL = `UPDATE n_auth_sessions SET revoked_at = CURRENT_TIMESTAMP
WHERE session_id = :session_id AND user_id = :user_id AND revoked_at IS NULL
AND access_jti = :access_jti`
const RotateSQL = `UPDATE n_auth_sessions
SET access_jti = :access_jti, refresh_token_hash = :refresh_token_hash,
access_token_expires_at = :access_token_expires_at, refresh_token_expires_at = :refresh_token_expires_at,
last_refresh_at = CURRENT_TIMESTAMP, last_accessed_at = CURRENT_TIMESTAMP
WHERE session_id = :session_id AND user_id = :user_id AND refresh_token_hash = :old_refresh_token_hash
AND revoked_at IS NULL AND refresh_token_expires_at > CURRENT_TIMESTAMP`
const PreflightSQL = `SELECT user_id, session_id, access_jti, access_token_expires_at, revoked_at, last_accessed_at,
refresh_token_hash, refresh_token_expires_at, last_refresh_at
FROM n_auth_sessions WHERE 1 = 0`

var errSessionStore = errors.New("session store unavailable")

type OracleSessions struct{ DB *sql.DB }

func (s OracleSessions) Touch(ctx context.Context, c auth.Claims) (int64, error) {
	return s.execute(ctx, TouchSQL, sql.Named("user_id", c.UserID), sql.Named("session_id", c.SessionID), sql.Named("access_jti", c.JTI))
}
func (s OracleSessions) Revoke(ctx context.Context, u int64, id string) (int64, error) {
	return s.execute(ctx, RevokeSQL, sql.Named("user_id", u), sql.Named("session_id", id))
}
func (s OracleSessions) RevokeOthers(ctx context.Context, u int64, id string) (int64, error) {
	return s.execute(ctx, RevokeOthersSQL, sql.Named("user_id", u), sql.Named("session_id", id))
}
func (s OracleSessions) RevokeRefresh(ctx context.Context, c auth.Claims, hash string) (int64, error) {
	return s.execute(ctx, LogoutRefreshSQL, sql.Named("session_id", c.SessionID), sql.Named("user_id", c.UserID), sql.Named("refresh_token_hash", hash))
}
func (s OracleSessions) RevokeAccess(ctx context.Context, c auth.Claims) (int64, error) {
	return s.execute(ctx, LogoutAccessSQL, sql.Named("session_id", c.SessionID), sql.Named("user_id", c.UserID), sql.Named("access_jti", c.JTI))
}
func (s OracleSessions) Rotate(ctx context.Context, rotation Rotation) (int64, error) {
	return s.execute(ctx, RotateSQL, sql.Named("access_jti", rotation.AccessJTI),
		sql.Named("refresh_token_hash", rotation.NewHash), sql.Named("access_token_expires_at", rotation.AccessExpiresAt),
		sql.Named("refresh_token_expires_at", rotation.RefreshExpiresAt), sql.Named("session_id", rotation.SessionID),
		sql.Named("user_id", rotation.UserID), sql.Named("old_refresh_token_hash", rotation.OldHash))
}

// Each operation commits independently. A successful touch never commits a later
// revoke, and a failed commit/connection release never authorizes a handler.
func (s OracleSessions) execute(ctx context.Context, query string, args ...interface{}) (count int64, err error) {
	conn, e := s.DB.Conn(ctx)
	if e != nil {
		return 0, errSessionStore
	}
	defer func() {
		if e := conn.Close(); e != nil {
			count = 0
			err = errSessionStore
		}
	}()
	tx, e := conn.BeginTx(ctx, nil)
	if e != nil {
		return 0, errSessionStore
	}
	defer tx.Rollback()
	result, e := tx.ExecContext(ctx, query, args...)
	if e != nil {
		return 0, errSessionStore
	}
	count, e = result.RowsAffected()
	if e != nil {
		return 0, errSessionStore
	}
	if e = tx.Commit(); e != nil {
		return 0, errSessionStore
	}
	return count, nil
}
func (s OracleSessions) Preflight(ctx context.Context) (err error) {
	conn, e := s.DB.Conn(ctx)
	if e != nil {
		return errSessionStore
	}
	defer func() {
		if e := conn.Close(); e != nil {
			err = errSessionStore
		}
	}()
	rows, e := conn.QueryContext(ctx, PreflightSQL)
	if e != nil {
		return errSessionStore
	}
	if e = rows.Close(); e != nil {
		return errSessionStore
	}
	return nil
}
